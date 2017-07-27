{-# LANGUAGE DataKinds, GADTs, TypeOperators, BangPatterns #-}
module Semantic.Task
( Task
, Level(..)
, RAlgebra
, Differ
, readBlobs
, readBlobPairs
, writeToOutput
, writeLog
, parse
, decorate
, diff
, render
, distribute
, distributeFor
, distributeFoldMap
, Options(..)
, defaultOptions
, configureOptionsForHandle
, runTask
, runTaskWithOptions
) where

import Control.Concurrent.STM.TMQueue
import Control.Exception
import Control.Monad.IO.Class
import Control.Parallel.Strategies
import qualified Control.Concurrent.Async as Async
import Control.Monad.Free.Freer
import Data.Blob
import qualified Data.ByteString as B
import Data.Functor.Both as Both
import Data.Record
import Data.String
import qualified Data.Syntax as Syntax
import Data.Syntax.Algebra (RAlgebra, decoratorWithAlgebra)
import qualified Data.Syntax.Assignment as Assignment
import qualified Data.Time.Clock as Time
import qualified Data.Time.Clock.POSIX as Time (getCurrentTime)
import qualified Data.Time.Format as Time
import Data.Union
import Diff
import qualified Files
import Language
import Language.Markdown
import Parser
import Prologue hiding (Location, show)
import System.Console.ANSI
import System.IO (hIsTerminalDevice, hPutStr)
import Term
import Text.Show
import Text.Printf
import TreeSitter

data TaskF output where
  ReadBlobs :: Either Handle [(FilePath, Maybe Language)] -> TaskF [Blob]
  ReadBlobPairs :: Either Handle [Both (FilePath, Maybe Language)] -> TaskF [Both Blob]
  WriteToOutput :: Either Handle FilePath -> ByteString -> TaskF ()
  WriteLog :: Level -> String -> [(String, String)] -> TaskF ()
  Parse :: Parser term -> Blob -> TaskF term
  Decorate :: Functor f => RAlgebra (TermF f (Record fields)) (Term f (Record fields)) field -> Term f (Record fields) -> TaskF (Term f (Record (field ': fields)))
  Diff :: Differ f a -> Both Blob -> Both (Term f a) -> TaskF (Diff f a)
  Render :: Renderer input output -> input -> TaskF output
  Distribute :: Traversable t => t (Task output) -> TaskF (t output)
  LiftIO :: IO a -> TaskF a

-- | A high-level task producing some result, e.g. parsing, diffing, rendering. 'Task's can also specify explicit concurrency via 'distribute', 'distributeFor', and 'distributeFoldMap'
type Task = Freer TaskF

-- | A log message at a specific level.
data Message = Message Level String Time.UTCTime
  deriving (Eq, Show)

data Level
  = Error
  | Warning
  | Info
  | Debug
  deriving (Eq, Ord, Show)

-- | Format a 'Message', optionally colourized.
formatMessage :: Bool -> Message -> String
formatMessage colourize (Message level message time) = showChar '[' . showTime time . showString "] " . showLevel level . showString " " . showString message . showChar '\n' $ ""
  where showLevel Error = Assignment.withSGRCode colourize [SetColor Foreground Vivid Red, SetConsoleIntensity BoldIntensity] (showString "ERROR")
        showLevel Warning = Assignment.withSGRCode colourize [SetColor Foreground Vivid Yellow, SetConsoleIntensity BoldIntensity] (showString " WARN")
        showLevel Info = Assignment.withSGRCode colourize [SetConsoleIntensity BoldIntensity] (showString " INFO")
        showLevel Debug = Assignment.withSGRCode colourize [SetColor Foreground Vivid Cyan, SetConsoleIntensity BoldIntensity] (showString "DEBUG")
        showTime = showString . Time.formatTime Time.defaultTimeLocale (Time.iso8601DateFormat (Just "%H:%M:%S%..%q"))


-- | A function to compute the 'Diff' for a pair of 'Term's with arbitrary syntax functor & annotation types.
type Differ f a = Both (Term f a) -> Diff f a

-- | A function to render terms or diffs.
type Renderer i o = i -> o

-- | A 'Task' which reads a list of 'Blob's from a 'Handle' or a list of 'FilePath's optionally paired with 'Language's.
readBlobs :: Either Handle [(FilePath, Maybe Language)] -> Task [Blob]
readBlobs from = ReadBlobs from `Then` return

-- | A 'Task' which reads a list of pairs of 'Blob's from a 'Handle' or a list of pairs of 'FilePath's optionally paired with 'Language's.
readBlobPairs :: Either Handle [Both (FilePath, Maybe Language)] -> Task [Both Blob]
readBlobPairs from = ReadBlobPairs from `Then` return

-- | A 'Task' which writes a 'ByteString' to a 'Handle' or a 'FilePath'.
writeToOutput :: Either Handle FilePath -> ByteString -> Task ()
writeToOutput path contents = WriteToOutput path contents `Then` return


-- | A 'Task' which logs a message at a specific log level to stderr.
writeLog :: Level -> String -> [(String, String)] -> Task ()
writeLog level message pairs = WriteLog level message pairs `Then` return


-- | A 'Task' which parses a 'Blob' with the given 'Parser'.
parse :: Parser term -> Blob -> Task term
parse parser blob = Parse parser blob `Then` return

-- | A 'Task' which decorates a 'Term' with values computed using the supplied 'RAlgebra' function.
decorate :: Functor f => RAlgebra (TermF f (Record fields)) (Term f (Record fields)) field -> Term f (Record fields) -> Task (Term f (Record (field ': fields)))
decorate algebra term = Decorate algebra term `Then` return

-- | A 'Task' which diffs a pair of terms using the supplied 'Differ' function.
diff :: Differ f a -> Both Blob -> Both (Term f a) -> Task (Diff f a)
diff differ blobs terms = Diff differ blobs terms `Then` return

-- | A 'Task' which renders some input using the supplied 'Renderer' function.
render :: Renderer input output -> input -> Task output
render renderer input = Render renderer input `Then` return

-- | Distribute a 'Traversable' container of 'Task's over the available cores (i.e. execute them concurrently), collecting their results.
--
--   This is a concurrent analogue of 'sequenceA'.
distribute :: Traversable t => t (Task output) -> Task (t output)
distribute tasks = Distribute tasks `Then` return

-- | Distribute the application of a function to each element of a 'Traversable' container of inputs over the available cores (i.e. perform the function concurrently for each element), collecting the results.
--
--   This is a concurrent analogue of 'for' or 'traverse' (with the arguments flipped).
distributeFor :: Traversable t => t a -> (a -> Task output) -> Task (t output)
distributeFor inputs toTask = distribute (fmap toTask inputs)

-- | Distribute the application of a function to each element of a 'Traversable' container of inputs over the available cores (i.e. perform the function concurrently for each element), combining the results 'Monoid'ally into a final value.
--
--   This is a concurrent analogue of 'foldMap'.
distributeFoldMap :: (Traversable t, Monoid output) => (a -> Task output) -> t a -> Task output
distributeFoldMap toTask inputs = fmap fold (distribute (fmap toTask inputs))

-- | Options controlling 'Task' logging, error handling, &c.
data Options = Options
  { optionsColour :: Maybe Bool -- ^ Whether to use colour formatting for errors. 'Nothing' implies automatic selection for the stderr handle, using colour for terminal handles but not for regular files.
  , optionsLevel :: Maybe Level -- ^ What level of messages to log. 'Nothing' disabled logging.
  , optionsPrintSource :: Bool -- ^ Whether to print the source reference when logging errors.
  }

defaultOptions :: Options
defaultOptions = Options
  { optionsColour = Nothing
  , optionsLevel = Just Warning
  , optionsPrintSource = False
  }

configureOptionsForHandle :: Handle -> Options -> IO Options
configureOptionsForHandle handle options = do
  isTerminal <- hIsTerminalDevice handle
  pure $ options
    { optionsColour = optionsColour options <|> Just isTerminal
    }


-- | Execute a 'Task' with the 'defaultOptions', yielding its result value in 'IO'.
--
-- > runTask = runTaskWithOptions defaultOptions
runTask :: Task a -> IO a
runTask = runTaskWithOptions defaultOptions

-- | Execute a 'Task' with the passed 'Options', yielding its result value in 'IO'.
runTaskWithOptions :: Options -> Task a -> IO a
runTaskWithOptions options task = do
  options <- configureOptionsForHandle stderr options
  logQueue <- newTMQueueIO
  logging <- async (logSink options logQueue)

  result <- run options logQueue task
  atomically (closeTMQueue logQueue)
  wait logging
  case result of
    Left err -> die err
    Right output -> pure output
  where logSink options queue = do
          message <- atomically (readTMQueue queue)
          case message of
            Just message -> do
              hPutStr stderr (formatMessage (fromMaybe True (optionsColour options)) message)
              logSink options queue
            _ -> pure ()
        run :: Options -> TMQueue Message -> Task a -> IO (Either String a)
        run options logQueue = go
          where go :: Task a -> IO (Either String a)
                go = iterFreerA (\ task yield -> case task of
                  ReadBlobs source -> (either Files.readBlobsFromHandle (traverse (uncurry Files.readFile)) source >>= yield) `catchError` \ e -> pure (Left (displayException e))
                  ReadBlobPairs source -> (either Files.readBlobPairsFromHandle (traverse (traverse (uncurry Files.readFile))) source >>= yield) `catchError` \ e -> pure (Left (displayException e))
                  WriteToOutput destination contents -> either B.hPutStr B.writeFile destination contents >>= yield
                  WriteLog level msg pairs
                    | Just logLevel <- optionsLevel options, level <= logLevel -> let message = printf "%-20s %s" msg (foldr (\ a b -> uncurry (printf "%s=%s") a <> " " <> b) ("" :: String) pairs) in Time.getCurrentTime >>= atomically . writeTMQueue logQueue . Message level message >>= yield
                    | otherwise -> pure () >>= yield
                  Parse parser blob -> go (runParser options parser blob) >>= either (pure . Left) (either (pure . Left) yield)
                  Decorate algebra term -> pure (decoratorWithAlgebra algebra term) >>= yield
                  Diff differ blobs terms -> do
                    start <- liftIO Time.getCurrentTime
                    !res <- pure (differ terms)
                    end <- liftIO Time.getCurrentTime
                    let (a, b) = runJoin blobs
                    _ <- go $ writeLog Info "diff" [ ("before_path", blobPath a)
                                                   , ("before_language", maybe "" show (blobLanguage a))
                                                   , ("after_path", blobPath b)
                                                   , ("after_language", maybe "" show (blobLanguage b))
                                                   , ("time", show (Time.diffUTCTime end start)) ]
                    yield res
                  Render renderer input -> pure (renderer input) >>= yield
                  Distribute tasks -> Async.mapConcurrently go tasks >>= either (pure . Left) yield . sequenceA . withStrategy (parTraversable (parTraversable rseq))
                  LiftIO action -> action >>= yield ) . fmap Right

runParser :: Options -> Parser term -> Blob -> Task (Either String term)
runParser options parser blob@Blob{..} = case parser of
  ASTParser language -> do
    start <- liftIO Time.getCurrentTime
    let !res = liftIO (Right <$> parseToAST language blob)
    end <- liftIO Time.getCurrentTime
    writeLog Info "parse" [ ("path", blobPath)
                          , ("language", maybe "" show blobLanguage)
                          , ("time", show (Time.diffUTCTime end start)) ]
    res
  AssignmentParser parser by assignment -> do
    res <- runParser options parser blob
    case res of
      Left err -> pure $ Left err -- Should never happen right now b/c ASTParser always returns Right ...
      Right ast -> do
        start <- liftIO Time.getCurrentTime
        let !assigned = Assignment.assignBy by blobSource assignment ast
        end <- liftIO Time.getCurrentTime
        case assigned of
          Left err -> do
            let formatOptions = Assignment.defaultOptions
                  { Assignment.optionsColour = fromMaybe True (optionsColour options)
                  , Assignment.optionsIncludeSource = optionsPrintSource options
                  }
            writeLog Error (Assignment.formatErrorWithOptions formatOptions blob err) []
            pure $ Left (showBlob blob <> " failed assignment")
          Right term -> do
            when (hasErrors term) $ writeLog Warning (showBlob blob <> " has parse errors") []
            writeLog Info "assign" [ ("path", blobPath)
                                   , ("language", maybe "" show blobLanguage)
                                   , ("time", show (Time.diffUTCTime end start)) ]
            pure $ Right term
  TreeSitterParser tslanguage -> liftIO $ Right <$> treeSitterParser tslanguage blob
  MarkdownParser -> pure $ Right (cmarkParser blobSource)
  LineByLineParser -> pure $ Right (lineByLineParser blobSource)
  where
    showBlob Blob{..} = blobPath <> ":" <> maybe "" show blobLanguage
    hasErrors :: (Syntax.Error :< fs, Foldable (Union fs), Functor (Union fs)) => Term (Union fs) (Record Assignment.Location) -> Bool
    hasErrors = cata $ \ (_ :< syntax) -> case syntax of
      _ | Just err <- prj syntax -> const True (err :: Syntax.Error Bool)
      _ -> or syntax

instance MonadIO Task where
  liftIO action = LiftIO action `Then` return
