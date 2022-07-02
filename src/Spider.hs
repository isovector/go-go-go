{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TupleSections         #-}
{-# LANGUAGE TypeApplications #-}

module Spider where

import qualified Data.Set as S
import Data.Set (Set)
import           Control.Exception (catch)
import           Control.Monad (forever, when, void)
import           Control.Monad.Reader (runReaderT)
import           DB
import           Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BS
import           Data.Foldable (for_, find)
import           Data.Function (on)
import           Data.Functor.Identity (Identity)
import           Data.Map (Map)
import qualified Data.Map as M
import qualified Data.Text as T
import           Data.Text.Lazy (toStrict)
import           Data.Text.Lazy.Encoding (decodeUtf8)
import           Data.Traversable (for)
import           Hasql.Connection (acquire, Connection)
import           Hasql.Session (run, statement)
import qualified Network.HTTP.Client as HTTP
import qualified Network.HTTP.Client.TLS as HTTP
import           Network.HTTP.Types (hContentType)
import           Network.URI (parseURI, URI)
import           Rel8
import           Signals
import           Text.HTML.Scalpel (scrapeURL)
import           Types
import           Utils (runRanker)
import Data.Text (Text)
import Data.Coerce (coerce)
import Data.Bifunctor (first, second)
import Data.Int (Int64, Int16)
import Data.Containers.ListUtils (nubOrd)
import Data.Functor ((<&>))
import Control.Applicative (liftA2)
import Keywords (posWords)

-- main :: IO ()
main = searchMain

--

nextDiscovered :: Query (Discovery Expr)
nextDiscovered = limit 1 $ do
  d <- each discoverySchema
  where_ $ d_state d ==. lit Discovered
  pure d


markExplored :: DiscoveryState -> Discovery Identity -> Update ()
markExplored ds d = Update
  { target = discoverySchema
  , from = pure ()
  , set = \ _ dis -> dis { d_state = lit ds }
  , updateWhere = \ _ dis -> d_docId dis ==. lit (d_docId d)
  , returning = pure ()
  }


docIdFor :: URI -> Query (Expr DocId)
docIdFor uri = do
  dis <- each discoverySchema
  where_ $ d_uri dis ==. lit (T.pack $ show uri)
  pure $ d_docId dis


getWordIds :: [Keyword] -> Query (Words Expr)
getWordIds kws = do
  w <- each wordsSchema
  where_ $ in_ (w_word w) $ fmap (lit . getKeyword) kws
  pure w

createWordIds :: [Keyword] -> Insert [Words Identity]
createWordIds kws = Insert
  { into = wordsSchema
  , rows = do
      wid <- nextWordId
      kw <- values $ fmap (lit . getKeyword) kws
      pure $ Words
        { w_wordId = wid
        , w_word = kw
        }
  , onConflict = DoNothing
  , returning = Projection id
  }


insertKeywords :: DocId -> [(Int, WordId)] -> Insert ()
insertKeywords did kws = Insert
  { into = indexSchema
  , rows = do
      iid <- nextIndexId
      (pos, wid) <- values $ fmap (lit . first (fromIntegral @_ @Int16)) kws
      pure $ Index
        { i_id = iid
        , i_docId  = lit did
        , i_wordId = wid
        , i_position = pos
        }
  , onConflict = DoNothing
  , returning = pure ()
  }


indexWords :: Connection -> DocId -> [(Int, Keyword)] -> IO ()
indexWords conn did pos = do
  let kws = nubOrd $ fmap snd pos
  flip run conn $ statement () $ insert $ createWordIds kws
  Right ws <- flip run conn $ statement () $ select $ getWordIds kws
  let word_map = M.fromList $ ws <&> \(Words a b) -> (Keyword b, a)
      pos' = fmap (second (word_map M.!)) pos
  Right res <- flip run conn $ statement () $ insert $ insertKeywords did pos'
  pure res


getDocId :: Connection -> URI -> IO DocId
getDocId conn uri = do
    Right dids <- flip run conn $ statement () $ select $ docIdFor uri
    case dids of
      [did] -> pure did
      [] -> do
        putStrLn $ "discovering " <> show uri
        Right dids <- flip run conn $ statement () $ insert $ discover uri
        pure $ head dids
      _ -> error $ "invalid database state: " <> show dids


discover :: URI -> Insert [DocId]
discover uri = Insert
  { into = discoverySchema
  , rows = do
      docid <- nextDocId
      pure $ Discovery docid (lit $ T.pack $ show uri) $ lit Discovered
  , onConflict = DoNothing
  , returning = Projection d_docId
  }


addEdge :: DocId -> Link DocId -> Insert [EdgeId]
addEdge src (Link anchor dst) = Insert
  { into = edgesSchema
  , rows = do
      eid <- nextEdgeId
      pure $ Edges eid (lit src) (lit dst) $ lit anchor
  , onConflict = DoNothing
  , returning = Projection e_edgeId
  }


buildEdges :: Connection -> DocId -> [Link URI] -> IO [EdgeId]
buildEdges conn did ls = do
  ldocs <- (traverse . traverse) (getDocId conn) ls
  for ldocs $ \l -> do
    -- putStrLn $ "edge ->" <> show (did, l_uri l)
    Right [eid] <- flip run conn $ statement () $ insert $ addEdge did l
    pure eid


getDocs :: [WordId] -> Query (Discovery Expr)
getDocs [] = do
  where_ $ true ==. false
  pure $ lit $ Discovery (DocId 0) "" Discovered
getDocs wids = distinct $ do
  d <- each discoverySchema
  for_ wids $ \wid -> do
    w <- each indexSchema
    where_ $ d_docId d ==. i_docId w &&. i_wordId w ==. lit wid
  pure d


search :: Connection -> [Keyword] -> IO [Text]
search conn kws = do
  Right wids <- flip run conn $ statement () $ select $ getWordIds kws
  let not_in_corpus = S.fromList kws S.\\ S.fromList (fmap (Keyword . w_word) wids)
  print not_in_corpus
  Right docs <- flip run conn $ statement () $ select $ getDocs $ fmap w_wordId wids
  pure $ fmap d_uri docs



searchMain :: IO [Text]
searchMain = do
  Right conn <- acquire connectionSettings
  search conn ["intelligence", "math", "machine", "functional", "whale", "critique", "ptsd", "jerkishness"]



spiderMain :: IO ()
spiderMain = do
  Right conn <- acquire connectionSettings
  forever $ do
    Right [disc] <- flip run conn $ statement () $ select nextDiscovered
    let url = d_uri disc
    case parseURI $ T.unpack url of
      Nothing -> error $ "died on bad URI: " <> show url
      Just uri -> do
        putStrLn $ "fetching " <> T.unpack url
        catch
          (do
            (mime, body) <- downloadBody $ T.unpack url
            when (mime == Just "text/html" && isAcceptableLink uri) $ do
              let Just (ls, ws) = runRanker uri body $ liftA2 (,) links posWords
              buildEdges conn (d_docId disc) ls
              indexWords conn (d_docId disc) ws
            putStrLn $ "explored " <> show (d_docId disc)
            flip run conn $ statement () $ update $ markExplored Explored disc
          )
          (\(HTTP.HttpExceptionRequest{}) -> do
            putStrLn $ "errored on " <> show (d_docId disc)
            flip run conn $ statement () $ update $ markExplored Errored disc
          )


downloadBody :: String -> IO (Maybe ByteString, T.Text)
downloadBody url = do
    manager <- maybe HTTP.getGlobalManager pure Nothing
    resp <- flip HTTP.httpLbs manager =<< HTTP.parseRequest url
    let mime = fmap (BS.takeWhile (/= ';'))
             $ lookup hContentType
             $ HTTP.responseHeaders resp
    pure $ (mime, ) $ toStrict $ decodeUtf8 $ HTTP.responseBody resp

