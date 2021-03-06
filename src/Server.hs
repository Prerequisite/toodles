{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators       #-}

module Server where

import           Config
import           License
import           Parse
import           Paths_toodles
import           ToodlesApi
import           Types

import qualified Control.Exception      as E
import           Control.Monad
import           Control.Monad.IO.Class
import           Data.Aeson             (FromJSON)
import           Data.Aeson.Types
import           Data.Either
import           Data.IORef
import           Data.List              (find, nub)
import           Data.Maybe
import           Data.String.Utils
import           Data.Text              (Text)
import qualified Data.Text              as T
import qualified Data.Yaml              as Y
import           Servant
import           System.Directory
import           System.Directory.Extra
import qualified System.IO.Strict       as SIO
import           System.Path.NameManip
import           Text.Blaze.Html5       (Html)
import qualified Text.Blaze.Html5       as BZ
import           Text.Printf
import           Text.Regex.Posix

freeResultsLimit :: Int
freeResultsLimit = 100

data ToodlesConfig = ToodlesConfig
  { ignore :: [FilePath]
  , flags  :: [UserFlag]
  } deriving (Show)

instance FromJSON ToodlesConfig where
  parseJSON (Object o) = do
    parsedIgnore <- o .:? "ignore"  .!= []
    parsedFlags <- o .:? "flags"  .!= []
    return $ ToodlesConfig parsedIgnore parsedFlags
  parseJSON invalid    = typeMismatch "Invalid config" invalid

app :: ToodlesState -> Application
app s = serve toodlesAPI server

    where
    server :: Server ToodlesAPI
    server = liftIO . getFullSearchResults s
        :<|> deleteTodos s
        :<|> editTodos s
        :<|> getLicense s
        :<|> serveDirectoryFileServer (dataPath s)
        :<|> showRawFile s
        :<|> root s

root :: ToodlesState -> [Text] -> Handler Html
root (ToodlesState _ dPath _) path =
    if null path then
        liftIO $ BZ.preEscapedToHtml <$> readFile (dPath ++ "/html/index.html")
    else throwError $ err404 { errBody = "Not found" }

getLicense :: ToodlesState -> Handler GetLicenseResponse
getLicense (ToodlesState _ _ tierRef) = do
  license <- liftIO readUserTier
  _ <- liftIO $ atomicModifyIORef' tierRef (const (license, license))
  return $ GetLicenseResponse license

readUserTier :: IO UserTier
readUserTier = do
  dataDir <- getDataDir
  licenseRead <- readLicense (dataDir ++ "/toodles-license-public-key.pem") "/etc/toodles/license.json"
  return $ either BadLicense id licenseRead

showRawFile :: ToodlesState -> Integer -> Handler Html
showRawFile (ToodlesState ref _ _) eId = do
    storedResults <- liftIO $ readIORef ref
    case storedResults of
      (Just (TodoListResult r _)) -> do
        let entry = find (\t -> entryId t == eId) r
        liftIO $
            maybe
            (return "Not found")
            (\e -> addAnchors <$> readFile (sourceFile e))
            entry
      Nothing -> error "no files to show"

    where
    addAnchors :: String -> Html
    addAnchors s =
        let codeLines = zip [1::Int ..] $ lines s
        in BZ.preEscapedToHtml
            (unlines $
            map
                (\(i, l) -> printf "<pre><a name=\"line-%s\">%s</a></pre>" (show i) l)
                codeLines)

editTodos :: ToodlesState -> EditTodoRequest -> Handler Text
editTodos s@(ToodlesState ref _ _) req = do
  storedResults <- liftIO $ readIORef ref
  case storedResults of
    (Just (TodoListResult r _)) -> do
      let editedList =
            map
              (\t ->
                if willEditTodo req t
                  then editTodo req t
                  else t)
              r
          editedFilteredList = filter (willEditTodo req) editedList
      _ <- mapM_ recordUpdates editedFilteredList
      _ <- updateCache s editedFilteredList
      return "{}"
    Nothing -> error "no stored todos to edit"
  where
    willEditTodo :: EditTodoRequest -> TodoEntry -> Bool
    willEditTodo editRequest entry = entryId entry `elem` editIds editRequest

    editTodo :: EditTodoRequest -> TodoEntry -> TodoEntry
    editTodo editRequest entry =
      let newAssignee =
            if isJust (setAssignee editRequest) &&
               (not . T.null . fromJust $ setAssignee editRequest)
              then setAssignee editRequest
              else assignee entry
          newPriority =
            if isJust (setPriority editRequest)
              then setPriority editRequest
              else priority entry
      in entry
         { assignee = newAssignee
         , tags = tags entry ++ addTags editRequest
         , priority = newPriority
         , customAttributes =
             nub $ customAttributes entry ++ addKeyVals editRequest
         }

    recordUpdates :: MonadIO m => TodoEntry -> m ()
    recordUpdates t = void $ updateTodoLinesInFile renderTodo t

data UpdateType = UpdateTypeEdit | UpdateTypeDelete deriving (Eq)

updateCache :: MonadIO m => ToodlesState -> [TodoEntry] -> m ()
updateCache (ToodlesState ref _ _) entries = do
  storedResults <- liftIO $ readIORef ref
  case storedResults of
    (Just (TodoListResult currentCache resultLimit)) -> do
      let idsToUpdate = map entryId entries
          newCache =
            TodoListResult
              ((++ entries)
                 (filter
                    (\item -> entryId item `notElem` idsToUpdate)
                    currentCache))
              resultLimit
      _ <-
        liftIO $ atomicModifyIORef' ref (const (Just newCache, Just newCache))
      return ()
    Nothing -> error "no stored todos to update"

renderTodo :: TodoEntry -> [Text]
renderTodo t =
  let ext = "." <> getExtension (sourceFile t)
      comment =
        if commentType t == SingleLine
          then fromJust $ singleLineCommentForExtension ext
          else fromJust $ multiLineOpenCommentForExtension ext
      detail =
        renderFlag (flag t) <> " (" <>
        T.pack (
         Data.String.Utils.join
           "|"
           (map T.unpack $
            [fromMaybe "" $ assignee t] ++
            listIfNotNull
              (fmap (T.pack . maybe "" ((\n -> "p=" ++ n) . show)) priority t) ++
            tags t ++ map (\a -> fst a <> "=" <> snd a) (customAttributes t))) <>
        ") "
      fullNoComments = mapHead (\l -> detail <> "- " <> l) $ body t
      commentFn =
        if commentType t == SingleLine
          then (\l -> comment <> " " <> l)
          else id
      commented = map commentFn fullNoComments
  in mapLast
       (\line ->
          if entryHeadClosed t
            then line <> " " <> getMultiClosingForFileType ext
            else line) .
     mapHead (\l -> if entryHeadOpened t then leadingText t <> getMultiOpeningForFileType ext <> " " <> l else leadingText t <> l) .
     mapInit
       (\l -> foldl (<>) "" [" " | _ <- [1 .. (T.length $ leadingText t)]] <> l) $
       commented
  where
    listIfNotNull :: Text -> [Text]
    listIfNotNull "" = []
    listIfNotNull s  = [s]

    renderFlag :: Flag -> Text
    renderFlag TODO              = "TODO"
    renderFlag FIXME             = "FIXME"
    renderFlag XXX               = "XXX"
    renderFlag (UF (UserFlag x)) = x

-- | Given a function to emit new lines for a given todo, write that update in
-- place of the current todo lines
updateTodoLinesInFile :: MonadIO m => (TodoEntry -> [Text]) -> TodoEntry -> m ()
updateTodoLinesInFile f todo = do
  let startIndex = lineNumber todo - 1
      newLines = map T.unpack $ f todo
  fileLines <- liftIO $ lines <$> SIO.readFile (sourceFile todo)
  let updatedLines =
        slice 0 (fromIntegral $ startIndex - 1) fileLines ++ newLines ++
        slice
           (fromIntegral startIndex + length (body todo))
           (length fileLines - 1)
           fileLines
  liftIO $ writeFile (sourceFile todo) $ unlines updatedLines

    where
    slice :: Int -> Int -> [a] -> [a]
    slice a b xs = take (b - a + 1) (drop a xs)

deleteTodos :: ToodlesState -> DeleteTodoRequest -> Handler Text
deleteTodos (ToodlesState ref _ _) req = do
    storedResults <- liftIO $ readIORef ref
    case storedResults of
      (Just refVal@(TodoListResult r _)) -> do
        let toDelete = filter (\t -> entryId t `elem` ids req) r
        liftIO $ doUntilNull removeAndAdjust toDelete
        let remainingResults = filter (\t -> entryId t `notElem` map entryId toDelete) r
        let updatedResults = foldl (flip adjustLinesAfterDeletionOf) remainingResults toDelete
        let remainingResultsRef = refVal { todos = updatedResults }
        _ <- liftIO $ atomicModifyIORef' ref (const (Just remainingResultsRef, Just remainingResultsRef))
        return "{}"
      Nothing -> error "no stored todos"

    where

    doUntilNull :: ([a] -> IO [a]) -> [a] -> IO ()
    doUntilNull f xs = do
        result <- f xs
        if null result
            then return ()
            else doUntilNull f result

    -- If we delete an entry, we need to decrement the line-numbers for the
    -- other entries that come later in the file
    adjustLinesAfterDeletionOf :: TodoEntry -> [TodoEntry] -> [TodoEntry]
    adjustLinesAfterDeletionOf deleted =
      map (\remaining ->
          if (sourceFile remaining == sourceFile deleted) && (lineNumber remaining > lineNumber deleted)
              then remaining { lineNumber = lineNumber remaining - (fromIntegral . length $ body deleted)}
              else remaining)

    removeAndAdjust :: MonadIO m => [TodoEntry] -> m [TodoEntry]
    removeAndAdjust [] = return []
    removeAndAdjust (x:xs) = do
        removeTodoFromCode x
        return $ adjustLinesAfterDeletionOf x xs

        where
        removeTodoFromCode :: MonadIO m => TodoEntry -> m ()
        removeTodoFromCode t =
          let opening = [getMultiOpeningForFileType $ getExtension (sourceFile t) | entryHeadOpened t]
              closing = [getMultiClosingForFileType $ getExtension (sourceFile t) | entryHeadClosed t]
              finalList = if length opening /= length closing then opening ++ closing else [] in
          updateTodoLinesInFile (const finalList) t

setAbsolutePath :: ToodlesArgs -> IO ToodlesArgs
setAbsolutePath args = do
    let pathOrDefault = if T.null . T.pack $ directory args
                            then "."
                            else directory args
    absolute <- normalise_path <$> absolute_path pathOrDefault
    return $ args {directory = absolute}

getFullSearchResults :: ToodlesState -> Bool -> IO TodoListResult
getFullSearchResults (ToodlesState ref _ tierRef) recompute = do
  result <- readIORef ref
  userLicense <- readIORef tierRef
  if recompute || isNothing result
    then do
      putStrLn "refreshing todo's"
      userArgs <- toodlesArgs >>= setAbsolutePath
      sResults <- runFullSearch (userArgs { limit_results = 0 })
      atomicModifyIORef' ref (const (Just sResults, sResults))
    else
      return $ fromMaybe (error "tried to read from the cache when there wasn't anything there") result

runFullSearch :: ToodlesArgs -> IO TodoListResult
runFullSearch userArgs = do
    let projectRoot = directory userArgs
    configExists <- doesFileExist $ projectRoot ++ "/.toodles.yaml"
    config <- if configExists
        then Y.decodeFileEither (projectRoot ++ "/.toodles.yaml")
        else return . Right $ ToodlesConfig [] []
    when (isLeft config)
        $ putStrLn $ "[WARNING] Invalid .toodles.yaml: " ++ show config
    let config' = fromRight (ToodlesConfig [] []) config
    allFiles <- getAllFiles config' projectRoot
    parsedTodos <- concat <$> mapM (parseFileAndLog userArgs config') allFiles
    let filteredTodos = filter (filterSearch (assignee_search userArgs)) parsedTodos
        resultList = limitSearch filteredTodos $ limit_results userArgs
        indexedResults = map (\(i, r) -> r {entryId = i}) $ zip [1 ..] resultList
        limit = limit_results userArgs
    return $ TodoListResult indexedResults (limit /= 0 && (length indexedResults >= limit))

    where
    filterSearch :: Maybe SearchFilter -> TodoEntry -> Bool
    filterSearch                                             Nothing     _ = True
    filterSearch (Just (AssigneeFilter (AssigneeFilterRegex query))) entry = fromMaybe "" (assignee entry) == query

    limitSearch :: [TodoEntry] -> Int -> [TodoEntry]
    limitSearch todoList 0 = todoList
    limitSearch todoList n = take n todoList

parseFileAndLog :: ToodlesArgs -> ToodlesConfig -> SourceFile -> IO [TodoEntry]
parseFileAndLog  userArgs config f = do
  -- the strictness is so we can print "done" when we're actually done
  !_ <- putStrLn $ fullPath f
  !result <- return (runTodoParser (userFlag userArgs ++ flags config) f)
  !_ <- putStrLn "done"
  return result

getAllFiles :: ToodlesConfig -> FilePath -> IO [SourceFile]
getAllFiles (ToodlesConfig ignoredPaths _) basePath =
  E.catch
    (do putStrLn $ printf "Running toodles for path: %s" basePath
        files <- listFilesInside (return . not . ignorePath) basePath
        let validFiles = filter isValidFile files
        mapM
          (\f ->
             SourceFile f . (map T.pack . lines) <$>
             E.catch
               (SIO.readFile f)
               (\(e :: E.IOException) -> print e >> return ""))
          validFiles)
    (\(e :: E.IOException) ->
       putStrLn ("Error reading " ++ basePath ++ ": " ++ show e) >> return [])

    where

    ignorePath :: FilePath -> Bool
    ignorePath path =
        let p = T.pack path
        in T.isInfixOf "node_modules" p || T.isSuffixOf "pb.go" p ||
            T.isSuffixOf "_pb2.py" p ||
            any (\r -> path =~ r :: Bool) ignoredPaths

    fileHasValidExtension :: FilePath -> Bool
    fileHasValidExtension path = any (\ext -> ext `T.isSuffixOf` T.pack path) (map extension fileTypeToComment)

    isValidFile :: FilePath -> Bool
    isValidFile path = not (ignorePath path) && fileHasValidExtension path


mapHead :: (a -> a) -> [a] -> [a]
mapHead f (x:xs) = f x : xs
mapHead _ xs     = xs

mapInit :: (a -> a) -> [a] -> [a]
mapInit f (x:xs) = x : map f xs
mapInit _ x      = x

mapLast :: (a -> a) -> [a] -> [a]
mapLast f xs
  | null xs = []
  | otherwise = init xs ++ [f $ last xs]
