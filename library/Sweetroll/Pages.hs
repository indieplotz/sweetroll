{-# LANGUAGE NoImplicitPrelude, OverloadedStrings, UnicodeSyntax #-}

-- | The definitions of pages
module Sweetroll.Pages where

import           Sweetroll.Prelude
import           Sweetroll.Slice
import           Sweetroll.Monads
import           Sweetroll.Conf

data View α = View
  { viewConf     ∷ SweetrollConf
  , viewRenderer ∷ ByteString → Value → Text
  , viewContent  ∷ α }

mkView ∷ α → Sweetroll (View α)
mkView cont = do
  conf ← getConf
  renderer ← getRenderer
  return $ View conf renderer cont

data EntryPage = EntryPage CategoryName [EntrySlug] (EntrySlug, Value)

data IndexedPage = IndexedPage [CategoryName] [Slice String] (HashMap String Value)
