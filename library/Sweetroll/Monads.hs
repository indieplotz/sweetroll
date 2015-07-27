{-# OPTIONS_GHC -fno-warn-orphans -fno-warn-missing-methods #-}
{-# LANGUAGE NoImplicitPrelude, OverloadedStrings, UnicodeSyntax #-}
{-# LANGUAGE PackageImports, ConstraintKinds, FlexibleContexts #-}
{-# LANGUAGE MultiParamTypeClasses, FlexibleInstances, UndecidableInstances #-}
{-# LANGUAGE RankNTypes, TypeOperators, TypeFamilies, DataKinds #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

-- | Monads that power Sweetroll and some common basic functions around them.
module Sweetroll.Monads (module Sweetroll.Monads) where

import           ClassyPrelude
import           System.IO.Unsafe
import           Control.Monad.Base
import           Control.Monad.Reader
import           Control.Monad.Except
import           Control.Monad.Trans.Either
import           Control.Monad.Trans.Resource
import           Control.Monad.Trans.Control
import           Data.Stringable hiding (length)
import           Data.Aeson.Types
import qualified Network.HTTP.Client.Conduit as H
import "crypto-random" Crypto.Random
import           Servant
import           Sweetroll.Conf

-- XXX: Temporary workaround because servant doesn't pass context yet
jwtSecret ∷ IORef Text
jwtSecret = unsafePerformIO $ newIORef ""
{-# NOINLINE jwtSecret #-}


data SweetrollCtx = SweetrollCtx
  { _ctxConf     ∷ SweetrollConf
  , _ctxTpls     ∷ SweetrollTemplates
  , _ctxSecs     ∷ SweetrollSecrets
  , _ctxHostInfo ∷ [Pair]
  , _ctxHttpMgr  ∷ H.Manager
  , _ctxRng      ∷ SystemRNG }

type MonadSweetroll = MonadReader SweetrollCtx

newtype Sweetroll α = Sweetroll {
  runSweetroll ∷ ReaderT SweetrollCtx (ExceptT ServantErr IO) α
} deriving (Functor, Applicative, Monad, MonadIO, MonadBase IO, MonadThrow, MonadError ServantErr,
            MonadSweetroll)

instance MonadBaseControl IO Sweetroll where
  type StM Sweetroll α = StM (ReaderT SweetrollCtx (ExceptT ServantErr IO)) α
  liftBaseWith f = Sweetroll $ liftBaseWith $ \r → f $ r . runSweetroll
  restoreM       = Sweetroll . restoreM

runSweetrollEither ∷ SweetrollCtx → Sweetroll α → EitherT ServantErr IO α
runSweetrollEither ctx sweet = EitherT $ liftIO $ runExceptT $ runReaderT (runSweetroll sweet) ctx

sweetrollToEither ∷ SweetrollCtx → Sweetroll :~> EitherT ServantErr IO
sweetrollToEither ctx = Nat $ runSweetrollEither ctx

initCtx ∷ SweetrollConf → SweetrollTemplates → SweetrollSecrets → IO SweetrollCtx
initCtx conf tpls secs = do
  httpClientMgr ← H.newManager
  sysRandom ← cprgCreate <$> createEntropyPool
  writeIORef jwtSecret $ secretKey secs
  return SweetrollCtx { _ctxConf     = conf
                      , _ctxTpls     = tpls
                      , _ctxSecs     = secs
                      , _ctxHostInfo = [ "domain"   .= domainName conf
                                       , "s"        .= s conf
                                       , "base_url" .= baseUrl conf ]
                      , _ctxHttpMgr  = httpClientMgr
                      , _ctxRng      = sysRandom }

getCtx ∷ MonadSweetroll μ ⇒ μ SweetrollCtx
getCtx = ask

getConf ∷ MonadSweetroll μ ⇒ μ SweetrollConf
getConf = asks _ctxConf

getConfOpt ∷ MonadSweetroll μ ⇒ (SweetrollConf → α) → μ α
getConfOpt f = asks $ f . _ctxConf

getTpls ∷ MonadSweetroll μ ⇒ μ SweetrollTemplates
getTpls = asks _ctxTpls

getSecs ∷ MonadSweetroll μ ⇒ μ SweetrollSecrets
getSecs = asks _ctxSecs

getSec ∷ MonadSweetroll μ ⇒ (SweetrollSecrets → α) → μ α
getSec f = asks $ f . _ctxSecs

getHostInfo ∷ MonadSweetroll μ ⇒ μ [Pair]
getHostInfo = asks _ctxHostInfo

getRng ∷ MonadSweetroll μ ⇒ μ SystemRNG
getRng = asks _ctxRng

instance H.HasHttpManager SweetrollCtx where
  getHttpManager = _ctxHttpMgr

-- | Convenient wrapper around Network.HTTP requests.
request ∷ (MonadSweetroll μ, MonadIO μ, Stringable α) ⇒ H.Request → μ (H.Response α)
request req = do
  resp ← H.httpLbs req
  return $ resp { H.responseBody = fromLazyByteString $ H.responseBody resp }

parseUrlP ∷ (MonadIO μ) ⇒ String → String → μ H.Request
parseUrlP postfix url = liftIO . H.parseUrl $ url ++ postfix
