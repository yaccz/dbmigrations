{-# LANGUAGE FlexibleContexts #-}
module Main
    ( main )
where

import System.Environment ( getArgs )
import System.Exit ( exitWith, ExitCode(..), exitSuccess )
import System.FilePath ( (</>) )

import Control.Exception ( bracket )

import Data.Maybe ( listToMaybe )
import Data.List ( intercalate )
import qualified Data.Map as Map
import Control.Monad ( when, forM_ )

import Database.HDBC.Sqlite3
    ( connectSqlite3
    , Connection
    )
import Database.HDBC
    ( IConnection(commit, rollback, disconnect)
    , catchSql
    , seErrorMsg
    , SqlError
    )
import Database.Schema.Migrations
    ( migrationsToApply
    , migrationsToRevert
    , missingMigrations
    , createNewMigration
    , ensureBootstrappedBackend
    )
import Database.Schema.Migrations.Filesystem
import Database.Schema.Migrations.Migration
    ( Migration(..)
    , MigrationMap
    )
import Database.Schema.Migrations.Backend
    ( Backend
    , applyMigration
    , revertMigration
    )
import Database.Schema.Migrations.Store
    ( loadMigrations
    , fullMigrationName
    )
import Database.Schema.Migrations.Backend.Sqlite()

-- A command has a name, a number of required arguments' labels, a
-- number of optional arguments' labels, and an action to invoke.
data Command = Command { cName :: String
                       , cRequired :: [String]
                       , cOptional :: [String]
                       , cDescription :: String
                       , cHandler :: CommandHandler
                       }
-- (required arguments, optional arguments) -> IO ()
type CommandHandler = ([String], [String]) -> IO ()

commands :: [Command]
commands = [ Command "new" ["store_path", "migration_name"] [] "Create a new empty migration" newCommand
           , Command "apply" ["store_path", "db_path", "migration_name"] []
                         "Apply the specified migration and its dependencies" applyCommand
           , Command "revert" ["store_path", "db_path", "migration_name"] []
                         "Revert the specified migration and those that depend on it" revertCommand
           , Command "test" ["store_path", "db_path", "migration_name"] []
                         "Test the specified migration by applying it and reverting it" testCommand
           , Command "upgrade" ["store_path", "db_path"] []
                         "Install all migrations that have not yet been installed" upgradeCommand
           , Command "upgrade-list" ["store_path", "db_path"] []
                         "Show the list of migrations to be installed during an upgrade" upgradeListCommand
           ]

withConnection :: FilePath -> (Connection -> IO a) -> IO a
withConnection dbPath act = bracket (connectSqlite3 dbPath) disconnect act

newCommand :: CommandHandler
newCommand (required, _) = do
  let [fsPath, migrationId] = required
      store = FSStore { storePath = fsPath }
  fullPath <- fullMigrationName store migrationId
  status <- createNewMigration store migrationId
  case status of
    Left e -> putStrLn e >> (exitWith (ExitFailure 1))
    Right _ -> putStrLn $ "Migration created successfully: " ++ (show fullPath)

upgradeCommand :: CommandHandler
upgradeCommand (required, _) = do
  let [fsPath, dbPath] = required
      store = FSStore { storePath = fsPath }
  mapping <- loadMigrations store

  withConnection dbPath $ \conn ->
      do
        ensureBootstrappedBackend conn >> commit conn
        migrationNames <- missingMigrations conn mapping
        when (null migrationNames) (putStrLn "Database is up to date." >> exitSuccess)
        forM_ migrationNames $ \migrationName -> do
            m <- lookupMigration mapping migrationName
            apply m mapping conn
        commit conn
        putStrLn $ "Database successfully upgraded."

upgradeListCommand :: CommandHandler
upgradeListCommand (required, _) = do
  let [fsPath, dbPath] = required
      store = FSStore { storePath = fsPath }
  mapping <- loadMigrations store

  withConnection dbPath $ \conn ->
      do
        ensureBootstrappedBackend conn >> commit conn
        migrationNames <- missingMigrations conn mapping
        when (null migrationNames) (putStrLn "Database is up to date." >> exitSuccess)
        putStrLn "Migrations to install:"
        forM_ migrationNames (putStrLn . ("  " ++))

reportSqlError :: SqlError -> IO a
reportSqlError e = do
  putStrLn $ "\nA database error occurred: " ++ seErrorMsg e
  exitWith (ExitFailure 1)

apply :: (Backend b IO) => Migration -> MigrationMap -> b -> IO [Migration]
apply m mapping backend = do
  -- Get the list of migrations to apply
  toApply' <- migrationsToApply mapping backend m
  toApply <- case toApply' of
               Left e -> do
                 putStrLn $ "Error: " ++ e
                 exitWith (ExitFailure 1)
               Right ms -> return ms

  -- Apply them
  if (null toApply) then
      (nothingToDo >> return []) else
      mapM_ (applyIt backend) toApply >> return toApply

    where
      nothingToDo = do
        putStrLn $ "Nothing to do; " ++
                     (mId m) ++
                     " already installed."

      applyIt conn it = do
        putStr $ "Applying: " ++ (mId it) ++ "... "
        applyMigration conn it
        putStrLn "done."

revert :: (Backend b IO) => Migration -> MigrationMap -> b -> IO [Migration]
revert m mapping backend = do
  -- Get the list of migrations to revert
  toRevert' <- migrationsToRevert mapping backend m
  toRevert <- case toRevert' of
                Left e -> do
                  putStrLn $ "Error: " ++ e
                  exitWith (ExitFailure 1)
                Right ms -> return ms

  -- Revert them
  if (null toRevert) then
      (nothingToDo >> return []) else
      mapM_ (revertIt backend) toRevert >> return toRevert

    where
      nothingToDo = do
        putStrLn $ "Nothing to do; " ++
                     (mId m) ++
                     " not installed."

      revertIt conn it = do
        putStr $ "Reverting: " ++ (mId it) ++ "... "
        revertMigration conn it
        putStrLn "done."

lookupMigration :: MigrationMap -> String -> IO Migration
lookupMigration mapping name = do
  let theMigration = Map.lookup name mapping
  case theMigration of
    Nothing -> do
      putStrLn $ "No such migration: " ++ name
      exitWith (ExitFailure 1)
    Just m' -> return m'

applyCommand :: CommandHandler
applyCommand (required, _) = do
  let [fsPath, dbPath, migrationId] = required
      store = FSStore { storePath = fsPath }
  mapping <- loadMigrations store

  withConnection dbPath $ \conn ->
      do
        ensureBootstrappedBackend conn >> commit conn
        m <- lookupMigration mapping migrationId
        apply m mapping conn
        commit conn
        putStrLn $ "Successfully applied migrations."

revertCommand :: CommandHandler
revertCommand (required, _) = do
  let [fsPath, dbPath, migrationId] = required
      store = FSStore { storePath = fsPath }
  mapping <- loadMigrations store

  withConnection dbPath $ \conn ->
      do
        ensureBootstrappedBackend conn >> commit conn
        m <- lookupMigration mapping migrationId
        revert m mapping conn
        commit conn
        putStrLn $ "Successfully reverted migrations."

testCommand :: CommandHandler
testCommand (required,_) = do
  let [fsPath, dbPath, migrationId] = required
      store = FSStore { storePath = fsPath }
  mapping <- loadMigrations store

  withConnection dbPath $ \conn ->
      do
        ensureBootstrappedBackend conn >> commit conn
        m <- lookupMigration mapping migrationId
        applied <- apply m mapping conn
        forM_ (reverse applied) $ \migration -> do
                             revert migration mapping conn
        rollback conn
        putStrLn $ "Successfully tested migrations."

usageString :: Command -> String
usageString command = intercalate " " ((cName command):requiredArgs ++ optionalArgs)
    where
      requiredArgs = map (\s -> "<" ++ s ++ ">") $ cRequired command
      optionalArgs = map (\s -> "[" ++ s ++ "]") $ cOptional command

usage :: IO a
usage = do
  putStrLn $ "Usage: initstore-fs <command> [args]"
  putStrLn "Commands:"
  forM_ commands $ \command -> do
          putStrLn $ "  " ++ usageString command
          putStrLn $ "    " ++ cDescription command
          putStrLn ""
  exitWith (ExitFailure 1)

usageSpecific :: Command -> IO a
usageSpecific command = do
  putStrLn $ "Usage: initstore-fs " ++ usageString command
  exitWith (ExitFailure 1)

findCommand :: String -> Maybe Command
findCommand name = listToMaybe [ c | c <- commands, cName c == name ]

main :: IO ()
main = do
  allArgs <- getArgs
  when (null allArgs) usage

  let (commandName:args) = allArgs

  command <- case findCommand commandName of
               Nothing -> usage
               Just c -> return c

  if (length args) < (length $ cRequired command) then
      usageSpecific command else
      (cHandler command $ splitAt (length $ cRequired command) args) `catchSql` reportSqlError