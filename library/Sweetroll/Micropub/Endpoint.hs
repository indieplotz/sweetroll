{-# LANGUAGE NoImplicitPrelude, OverloadedStrings, UnicodeSyntax #-}
{-# LANGUAGE FlexibleContexts, TypeFamilies, DataKinds #-}

module Sweetroll.Micropub.Endpoint (
  getMicropub
, postMicropub
) where

import           ClassyPrelude
import           Control.Concurrent.Lifted (fork, threadDelay)
import           Control.Monad.Trans.Control
import           Control.Lens hiding ((.=), (|>))
import           Data.Aeson
import           Data.Aeson.Lens
import           Data.String.Conversions
import qualified Data.Vector as V
import           Data.Foldable (asum)
import           Text.Pandoc hiding (Link, Null)
import           Text.Blaze.Html.Renderer.Text (renderHtml)
import           Network.URI
import           Network.HTTP.Client hiding (Proxy)
import           Network.HTTP.Client.Internal (setUri)
import qualified Network.HTTP.Types as HT
import           Web.JWT hiding (header, decode)
import           Servant
import           Gitson
import           Sweetroll.Conf
import           Sweetroll.Util
import           Sweetroll.Auth
import           Sweetroll.Monads
import           Sweetroll.Routes
import           Sweetroll.Micropub.Request
import           Sweetroll.Micropub.Response
import           Sweetroll.Webmention.Send

infixl 1 |>
(|>) ∷ Monad μ ⇒ μ α → (α → β) → μ β
(|>) = flip liftM

getMicropub ∷ JWT VerifiedJWT → Maybe Text → Sweetroll MicropubResponse
getMicropub _ (Just "syndicate-to") = do
  (MkSyndicationConfig syndConf) ← getConfOpt syndicationConfig
  return $ SyndicateTo $ case syndConf of
             Object o → keys o
             _ → []
getMicropub token _ = getAuth token |> AuthInfo

postMicropub ∷ JWT VerifiedJWT → MicropubRequest
             → Sweetroll (Headers '[Header "Location" Text] MicropubResponse)
postMicropub token (Create htype props synds) = do
  now ← liftIO getCurrentTime
  base ← getConfOpt baseURI
  isTest ← getConfOpt testMode
  (MkSyndicationConfig syndConf) ← getConfOpt syndicationConfig

  let syndLinks = getSyndLinks synds syndConf
      content = readContent =<< lookup "content" props
      category = decideCategory props
      slug = decideSlug props now
      absUrl = permalink (Proxy ∷ Proxy EntryRoute) category slug `relativeTo` base
  obj ← return props
        >>= fetchReplyContexts "in-reply-to"
        >>= fetchReplyContexts "like-of"
        >>= fetchReplyContexts "repost-of"
        |>  setDates now
        |>  setClientId token
        |>  setUrl absUrl
        |>  setContent content syndLinks
        |>  wrapWithType htype
        -- TODO: copy content for reposts
  transaction "./" $ saveNextDocument category slug obj
  unless isTest $ void $ fork $ do
    threadDelay =<< (*1000000) `liftM` getConfOpt pushDelay
    transaction "./" $ do
      -- check that it wasn't deleted after the delay
      obj'm ← readDocumentByName category slug
      case obj'm of
        Nothing → return ()
        Just obj' → do
          notifyPuSH $ permalink (Proxy ∷ Proxy IndexRoute)
          notifyPuSH $ permalink (Proxy ∷ Proxy CatRouteE) category
          saveDocumentByName category slug =<< syndicate obj' absUrl (cs syndLinks)
          contMs ← contentWebmentions content
          void $ sendWebmentions absUrl $ contMs ++ replyContextWebmentions obj'
  return $ addHeader (tshow absUrl) Posted

getSyndLinks ∷ [ObjSyndication] → Value → LText
getSyndLinks synds syndConf =
  case syndConf of
    Object o → cs $ concat $ mapMaybe (^? _String) $ mapMaybe (flip lookup o) $ filter inSyndicateTo $ keys o
    _ → ""
  where inSyndicateTo x = any (x `isInfixOf`) synds

fetchReplyContexts ∷ Text → ObjProperties → Sweetroll ObjProperties
fetchReplyContexts k props = do
    newCtxs ← updateCtxs $ lookup k props
    return $ insertMap k newCtxs props
  where updateCtxs (Just (Array v)) = Array `liftM` mapM fetch v
        updateCtxs _ = return $ Array V.empty
        fetch (String u) = case parseURI $ cs u of
          Nothing → return $ String u
          Just uri → do
            r ← withSuccessfulRequestHtml uri $ \resp →
              withFetchEntryWithAuthors uri resp $ \mfRoot ((Object entry), _) →
                return $ Object $ insertMap "webmention-endpoint" (toJSON $ map tshow $ discoverWebmentionEndpoints mfRoot (linksFromHeader resp))
                                $ insertMap "fetched-url" (toJSON u) entry
            return $ fromMaybe (String u) r
        fetch x = return x

-- XXX: not tested yet
replyContextWebmentions ∷ Value → [(TargetURI, EndpointURI)]
replyContextWebmentions obj =
  [ (tgt, endp) | k    ← [ "in-reply-to", "like-of", "repost-of" ]
                , ctx  ← obj ^.. key "properties" . key k . values
                , endp ← mapMaybe (parseURI . cs) $ ctx ^.. key "webmention-endpoint" . values . _String
                , tgt  ← maybeToList $ (parseURI . cs) =<< ctx ^? key "fetched-url" . _String ]

setDates ∷ UTCTime → ObjProperties → ObjProperties
setDates now = insertMap "updated" (toJSON [ now ]) . insertWith (\_ x → x) "published" (toJSON [ now ])

setClientId ∷ JWT VerifiedJWT → ObjProperties → ObjProperties
setClientId token = insertMap "client-id" $ toJSON $ filter (/= "example.com") $ catMaybes [ lookup "client_id" $ unregisteredClaims $ claims token ]

setUrl ∷ URI → ObjProperties → ObjProperties
setUrl url = insertMap "url" $ toJSON  [ tshow url ]

setContent ∷ Maybe Pandoc → LText → ObjProperties → ObjProperties
setContent content syndLinks = insertMap "content" $ toJSON [ object [ "html" .= h ] ]
  where h = (fromMaybe "" $ (renderHtml . writeHtml pandocWriterOptions) `liftM` content) ++ cs syndLinks

wrapWithType ∷ ObjType → ObjProperties → Value
wrapWithType htype props =
  object [ "type"       .= [ htype ]
         , "properties" .= insertMap "syndication" (Array V.empty) props ]

decideCategory ∷ ObjProperties → CategoryName
decideCategory props | hasProp "name"          = "articles"
                     | hasProp "in-reply-to"   = "replies"
                     | hasProp "like-of"       = "likes"
                     | otherwise               = "notes"
  where hasProp = isJust . flip lookup props

decideSlug ∷ ObjProperties → UTCTime → EntrySlug
decideSlug props now = unpack . fromMaybe fallback $ getProp "slug"
  where fallback = slugify . fromMaybe (formatTimeSlug now) $ getProp "name" <|> getProp "summary"
        formatTimeSlug = pack . formatTime defaultTimeLocale "%Y-%m-%d-%H-%M-%S"
        getProp k = firstStr (Object props) (key k)

readContent ∷ Value → Maybe Pandoc
readContent c = asum [ readWith readHtml       $ key "html"
                     , readWith readTextile    $ key "textile"
                     , readWith readOrg        $ key "org"
                     , readWith readRST        $ key "rst"
                     , readWith readLaTeX      $ key "tex"
                     , readWith readLaTeX      $ key "latex"
                     , readWith readMarkdown   $ key "markdown"
                     , readWith readMarkdown   $ key "gfm"
                     , readWith readCommonMark $ key "value"
                     , readWith readCommonMark id ]
  where readWith rdr l = pandocRead rdr . cs <$> firstStr c l

notifyPuSH ∷ (MonadIO μ, MonadBaseControl IO μ, MonadThrow μ, MonadSweetroll μ) ⇒
             URI → μ ()
notifyPuSH l = do
  hub ← getConfOpt pushHub
  case parseURI hub of
    Nothing → return ()
    Just hubURI → do
      base ← getConfOpt baseURI
      let pingURI = l `relativeTo` base
          body = writeForm [ (asText "hub.mode", asText "publish"), ("hub.url", tshow pingURI) ]
      let req = def { method = "POST"
                    , requestHeaders = [ (HT.hContentType, "application/x-www-form-urlencoded; charset=utf-8") ]
                    , requestBody = RequestBodyBS body }
      req' ← setUri req hubURI
      void $ withRequest req' $ \_ → do
        putStrLn $ "PubSubHubbub notified: " ++ cs body
        return $ Just ()

syndicate ∷ (MonadIO μ, MonadBaseControl IO μ, MonadThrow μ, MonadSweetroll μ) ⇒
            Value → URI → LText → μ Value
syndicate entry absUrl syndLinks = do
  syndMs ← contentWebmentions $ Just $ pandocRead readHtml $ cs syndLinks
  syndResults ← catMaybes `liftM` sendWebmentions absUrl syndMs
  let processSynd resp = do
        guard $ responseStatus resp `elem` [ HT.ok200, HT.created201 ]
        decodeUtf8 `liftM` lookup "Location" (responseHeaders resp)
  return $ set (key "properties" . key "syndication") (Array $ V.fromList $ map String $ mapMaybe processSynd syndResults) entry
