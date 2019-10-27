{-# LANGUAGE EmptyCase #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE EmptyCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE TypeOperators #-}

module Common.Route where

------------------------------------------------------------------------------
import           Prelude hiding ((.), id)
import           Control.Categorical.Bifunctor
import           Control.Category (Category (..))
import           Control.Category.Monoidal
import           Control.Monad.Except
import           Data.Functor.Identity
import           Data.Some (Some)
import qualified Data.Some as Some
import           Data.Text (Text)
import qualified Data.Text as T
import           Data.Text.Encoding hiding (Some)
import           Obelisk.Configs
import           Obelisk.Route
import           Obelisk.Route.TH
import           Reflex.Dom
------------------------------------------------------------------------------

------------------------------------------------------------------------------
-- START: Move to Obelisk.Route

infixr 5 :.
type (:.) = (,)

{-# COMPLETE (:.) #-}
pattern (:.) :: a -> b -> a :. b
pattern a :. b = (a, b)

addPathSegmentEncoder
  :: ( Applicative check
     , MonadError Text parse
     )
  => Encoder check parse (Text, PageName) PageName
addPathSegmentEncoder = unsafeMkEncoder $ EncoderImpl
  { _encoderImpl_encode = \(ph, (pt, q)) -> (ph : pt, q)
  , _encoderImpl_decode = \(p, q) -> case p of
      [] -> throwError "Expected a path segment"
      ph : pt -> pure (ph, (pt, q))
  }

pathParamEncoder
  :: forall check parse item rest.
     ( Applicative check
     , MonadError Text parse
     )
  => Encoder check parse item Text
  -> Encoder check parse rest PageName
  -> Encoder check parse (item :. rest) PageName
pathParamEncoder itemUnchecked restUnchecked = addPathSegmentEncoder . bimap itemUnchecked restUnchecked

pathLiteralEncoder
  :: ( Applicative check
     , MonadError Text parse
     )
  => Text
  -> Encoder check parse a PageName
  -> Encoder check parse a PageName
pathLiteralEncoder t e = addPathSegmentEncoder . bimap (unitEncoder t) e . coidl

-- END: Move to Obelisk.Route
------------------------------------------------------------------------------

data BackendRoute :: * -> * where
  -- | Used to handle unparseable routes.
  BackendRoute_Missing :: BackendRoute ()

data BlockRoute :: * -> * where
  Block_Header :: BlockRoute ()
  Block_Transactions :: BlockRoute ()

blockRouteEncoder
  :: Encoder (Either Text) (Either Text) (R BlockRoute) PageName
blockRouteEncoder = pathComponentEncoder $ \case
  Block_Header -> PathEnd $ unitEncoder mempty
  Block_Transactions -> PathSegment "txs" $ unitEncoder mempty

--blockRouteToPath :: BlockRoute () -> [Text]
--blockRouteToPath Block_Header = []
--blockRouteToPath Block_Transactions = ["txs"]

--blockRouteEncoder
--  :: Int
--  -> Text
--  -> Encoder (Either Text) (Either Text) (R BlockRoute) PageName
--blockRouteEncoder chainId blockHash = pathComponentEncoder $ \case
--  Block_Header -> PathEnd $ unitEncoder mempty
--  Block_Transactions -> PathSegment "txs" $ unitEncoder mempty

data FrontendRoute :: * -> * where
  FR_Main :: FrontendRoute ()
  FR_About :: FrontendRoute ()
  FR_Mainnet :: FrontendRoute BlockIdRoute
  FR_Testnet :: FrontendRoute BlockIdRoute
  FR_Customnet :: FrontendRoute (Domain :. BlockIdRoute)
  -- This type is used to define frontend routes, i.e. ones for which the backend will serve the frontend.

type BlockIdRoute = Int :. Text :. R BlockRoute

pathOnlyEncoderIgnoringQuery :: (Applicative check, MonadError Text parse) => Encoder check parse [Text] PageName
pathOnlyEncoderIgnoringQuery = unsafeMkEncoder $ EncoderImpl
  { _encoderImpl_decode = \(path, _query) -> pure path
  , _encoderImpl_encode = \path -> (path, mempty)
  }

--singletonListEncoder :: (Applicative check, MonadError Text parse) => Encoder check parse a [a]
--singletonListEncoder = unsafeMkEncoder $ EncoderImpl
--  { _encoderImpl_decode = \case
--      [a] -> pure a
--      l -> throwError $ "singletonListEncoderImpl: expected one item, got " <> tshow (length l)
--  , _encoderImpl_encode = (:[])
--  }


backendRouteEncoder
  :: Encoder (Either Text) Identity (R (FullRoute BackendRoute FrontendRoute)) PageName
backendRouteEncoder = handleEncoder (const (FullRoute_Backend BackendRoute_Missing :/ ())) $
  pathComponentEncoder $ \case
    FullRoute_Backend backendRoute -> case backendRoute of
      BackendRoute_Missing -> PathSegment "missing" $ unitEncoder mempty
    FullRoute_Frontend obeliskRoute -> obeliskRouteSegment obeliskRoute $ \case
      -- The encoder given to PathEnd determines how to parse query parameters,
      -- in this example, we have none, so we insist on it.
      FR_Main -> PathEnd $ unitEncoder mempty
      FR_About -> PathSegment "about" $ unitEncoder mempty
      FR_Mainnet -> PathSegment "mainnet" $ blockIdRouteEncoder
      FR_Testnet -> PathSegment "testnet" $ blockIdRouteEncoder
      FR_Customnet -> PathSegment "custom" $ pathParamEncoder id blockIdRouteEncoder

blockIdRouteEncoder :: Encoder (Either Text) (Either Text) BlockIdRoute PageName
blockIdRouteEncoder = pathLiteralEncoder "chain" $ pathParamEncoder unsafeTshowEncoder $ pathLiteralEncoder "block" $ pathParamEncoder id blockRouteEncoder

--TODO: Ensure it's really a valid domain name
type Domain = Text

data NetId
   = NetId_Mainnet
   | NetId_Testnet
   | NetId_Custom Domain

addNetRoute :: NetId -> BlockIdRoute -> R FrontendRoute
addNetRoute netId r = case netId of
  NetId_Mainnet -> FR_Mainnet :/ r
  NetId_Testnet -> FR_Testnet :/ r
  NetId_Custom domain -> FR_Customnet :/ domain :. r

concat <$> mapM deriveRouteComponent
  [ ''BackendRoute
  , ''FrontendRoute
  , ''BlockRoute
  ]

getAppRoute :: HasConfigs m => m Text
getAppRoute = do
    mroute <- getConfig "common/route"
    case mroute of
      Nothing -> fail "Error getAppRoute: config/common/route not defined"
      Just r -> return $ T.dropWhileEnd (== '/') $ T.strip $ decodeUtf8 r

-- | Provide a human-readable name for a given section
tabTitle :: DomBuilder t m => Some FrontendRoute -> m ()
tabTitle sfr@(Some.Some sec) = text $ frToText sfr

-- | Provide a human-readable name for a given section
frToText :: Some FrontendRoute -> Text
frToText (Some.Some sec) = case sec of
  FR_Main -> "Home"
  FR_About -> "About"
  FR_Mainnet -> "Block"
  FR_Testnet -> "Block"
  FR_Customnet -> "Block"
