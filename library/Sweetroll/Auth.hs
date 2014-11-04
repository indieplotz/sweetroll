{-# LANGUAGE NoImplicitPrelude, OverloadedStrings #-}

-- | The IndieAuth/rel-me-auth implementation, using JSON Web Tokens.
module Sweetroll.Auth (
  checkAuth
, showAuth
, makeAccessToken
, doIndieAuth
) where

import           ClassyPrelude
import           Data.Time.Clock.POSIX
import           Web.Scotty
import           Web.JWT hiding (header)
import           Network.HTTP.Types.Status
import           Network.HTTP.Client
import           Sweetroll.Util
import           Sweetroll.Conf

getAccessToken :: SweetrollAction Text
getAccessToken = do
  allParams <- params
  tokenHeader <- header "Authorization" >>= \x -> return $ fromMaybe "" $ drop 7 <$> x -- Drop "Bearer "
  return $ toStrict $ fromMaybe tokenHeader $ findByKey allParams "access_token"

checkAuth :: SweetrollConf -> SweetrollAction () -> SweetrollAction () -> SweetrollAction ()
checkAuth conf unauthorized act = do
  token <- getAccessToken
  let verResult = decodeAndVerifySignature (secret $ secretKey conf) token
  case verResult of
    Just _ -> act
    _ -> unauthorized

showAuth :: SweetrollAction ()
showAuth = do
  token <- getAccessToken
  case map claims $ decode token of
    Just cs ->
      showXForm $ "me=" ++ case sub cs of
        Just me -> pack $ show me
        _ -> ""
    _ -> status unauthorized401

makeAccessToken :: SweetrollConf -> Text -> SweetrollAction ()
makeAccessToken conf me = do
  now <- liftIO getCurrentTime
  let t = def { iss = stringOrURI $ domainName conf
              , sub = stringOrURI me
              , iat = intDate $ utcTimeToPOSIXSeconds now }
      t' = encodeSigned HS256 (secret $ secretKey conf) t
  status ok200
  text $ fromStrict $ mconcat ["access_token=", t', "&scope=post&me=", me]
  setHeader "Content-Type" "application/jwt"

doIndieAuth :: SweetrollConf -> SweetrollAction () -> Manager -> SweetrollAction ()
doIndieAuth conf unauthorized httpClientMgr = do
  allParams <- params
  let par x = toStrict <$> findByKey allParams x
      par' = fromMaybe "" . par
      valid = makeAccessToken conf $ par' "me"
  if testMode conf then valid else do
    let reqBody = encodeUtf8 $ mconcat ["code=", par' "code", "&redirect_uri=", par' "redirect_uri",
                                        "&client_id=", fromMaybe (baseURL conf) $ par "client_id", "&state=", par' "state"]
    indieAuthReq <- liftIO $ parseUrl (indieAuthEndpoint conf) >>= \x -> return $ x { method = "POST", secure = True }
    resp <- liftIO $ httpLbs (indieAuthReq { requestBody = RequestBodyBS reqBody }) httpClientMgr
    if responseStatus resp /= ok200 then unauthorized
    else valid
