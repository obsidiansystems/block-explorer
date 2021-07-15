{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE ScopedTypeVariables        #-}

-- {-# LANGUAGE ConstraintKinds            #-}
-- {-# LANGUAGE DataKinds                  #-}
-- {-# LANGUAGE GeneralizedNewtypeDeriving #-}
-- {-# LANGUAGE LambdaCase                 #-}
-- {-# LANGUAGE RecursiveDo                #-}
-- {-# LANGUAGE ScopedTypeVariables        #-}
-- {-# LANGUAGE TupleSections              #-}
-- {-# LANGUAGE TypeApplications           #-}
-- {-# LANGUAGE TypeFamilies               #-}
-- {-# LANGUAGE TypeOperators              #-}
module Frontend.Transactions where

------------------------------------------------------------------------------
import           Control.Lens
import           Control.Monad
import           Control.Monad.Reader
import           Data.Aeson.Lens
import Data.Dependent.Sum
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import           Data.Maybe
import qualified Data.Sequence as S
import           Data.Text (Text)
import qualified Data.Text as T
import           GHCJS.DOM.Types (MonadJSM)
import           Obelisk.Route
import           Obelisk.Route.Frontend
import           Reflex.Dom.Core hiding (Value)
import           Reflex.Network
import           Servant.Reflex
import           Text.Read
------------------------------------------------------------------------------
import           Chainweb.Api.ChainId
import           ChainwebData.Pagination
import           ChainwebData.TxSummary
import           ChainwebData.EventDetail
import           Common.Route
import           Common.Types
import           Common.Utils
import           Frontend.App
import           Frontend.AppState
import           Frontend.ChainwebApi
import           Frontend.Common
import           Frontend.Page.Block
------------------------------------------------------------------------------

recentTransactions
  :: (SetRoute t (R FrontendRoute) m,
      RouteToUrl (R FrontendRoute) m, MonadReader (AppState t1) m,
      HasJSContext (Performable m), MonadJSM (Performable m),
      DomBuilder t m, PerformEvent t m, TriggerEvent t m, PostBuild t m,
      Prerender js t m,
      MonadHold t m)
  => Int
  -> RecentTxs
  -> m ()
recentTransactions tcount txs = do
  net <- asks _as_network
  if S.null (_recentTxs_txs txs)
    then blank
    else do
      el "h4" $ text "Recent Transactions"
      txTable net $ take tcount $ getSummaries txs


qParam :: Text
qParam = "q"

limParam :: Text
limParam = "lim"

pageParam :: Text
pageParam = "page"

itemsPerPage :: Integer
itemsPerPage = 20

transactionSearch
    :: ( MonadApp r t m
       , Prerender js t m
       , MonadJSM (Performable m)
       , HasJSContext (Performable m)
       , RouteToUrl (R FrontendRoute) m
       , SetRoute t (R FrontendRoute) m
       )
    => App (Map Text (Maybe Text)) t m ()
transactionSearch = do
    (AppState n _ mdbh _) <- ask
    case mdbh of
      Nothing -> text "Transaction search feature not available for this network"
      Just dbh -> do
        pmap <- askRoute
        pb <- getPostBuild
        let page = do
              pm <- pmap
              pure $ fromMaybe 1 $ readMaybe . T.unpack =<< join (M.lookup pageParam pm)
            needle = do
              pm <- pmap
              pure $ fromMaybe "" $ join (M.lookup qParam pm)
            newSearch = leftmost [pb, () <$ updated pmap]
        res <- searchTxs dbh (constDyn $ QParamSome $ Limit itemsPerPage)
                             (QParamSome . Offset . (*itemsPerPage) . pred <$> page)
                             (QParamSome <$> needle) newSearch

        divClass "ui pagination menu" $ do
          let setSearchRoute f e = setRoute $
                tag (current $ mkTxSearchRoute n <$> needle <*> fmap (Just . f) page) e
              prevAttrs p = if p == 1
                              then "class" =: "disabled item"
                              else "class" =: "item"
          (p,_) <- elDynAttr' "div" (prevAttrs <$> page) $ text "Prev"
          setSearchRoute pred (domEvent Click p)
          divClass "disabled item" $ display page
          (next,_) <- elAttr' "div" ("class" =: "item") $ text "Next"
          setSearchRoute succ (domEvent Click next)

        let f = either text (txTable n)
        void $ networkHold (inlineLoader "Querying blockchain...") (f <$> res)

mkSearchRoute' :: NetId -> DSum NetRoute Identity -> R FrontendRoute
mkSearchRoute' netId r = case netId of
    NetId_Mainnet -> FR_Mainnet :/ r
    NetId_Testnet -> FR_Testnet :/ r
    NetId_Custom host -> FR_Customnet :/ (host, r)

mkTxSearchRoute :: NetId -> Text -> Maybe Integer -> R FrontendRoute
mkTxSearchRoute netId str page = mkSearchRoute' netId (NetRoute_TxSearch :/ (qParam =: Just str <> p ))
  where
    p = maybe mempty ((pageParam =:) . Just . tshow) page

eventSearch
    :: ( MonadApp r t m
       , Prerender js t m
       , MonadJSM (Performable m)
       , HasJSContext (Performable m)
       , RouteToUrl (R FrontendRoute) m
       , SetRoute t (R FrontendRoute) m
       )
    => App (Map Text (Maybe Text)) t m ()
eventSearch = do
    (AppState n _ mdbh _) <- ask
    case mdbh of
      Nothing -> text "Event search feature not available for this network"
      Just dbh -> do
        pmap <- askRoute
        pb <- getPostBuild
        let page = do
              pm <- pmap
              pure $ fromMaybe 1 $ readMaybe . T.unpack =<< join (M.lookup pageParam pm)
            needle = do
              pm <- pmap
              pure $ fromMaybe "" $ join (M.lookup qParam pm)
            newSearch = leftmost [pb, () <$ updated pmap]
        res <- searchEvents dbh
            (constDyn $ QParamSome $ Limit itemsPerPage)
            (QParamSome . Offset . (*itemsPerPage) . pred <$> page)
            (QParamSome <$> needle)
            (constDyn QNone)
            (constDyn QNone)
            (constDyn QNone)
            newSearch

        divClass "ui pagination menu" $ do
          let setSearchRoute f e = setRoute $
                tag (current $ mkEventSearchRoute n <$> needle <*> fmap (Just . f) page) e
              prevAttrs p = if p == 1
                              then "class" =: "disabled item"
                              else "class" =: "item"
          (p,_) <- elDynAttr' "div" (prevAttrs <$> page) $ text "Prev"
          setSearchRoute pred (domEvent Click p)
          divClass "disabled item" $ display page
          (next,_) <- elAttr' "div" ("class" =: "item") $ text "Next"
          setSearchRoute succ (domEvent Click next)

        let f = either text (evTable n)
        void $ networkHold (inlineLoader "Querying blockchain...") (f <$> res)

mkEventSearchRoute :: NetId -> Text -> Maybe Integer -> R FrontendRoute
mkEventSearchRoute netId str page = mkSearchRoute' netId (NetRoute_EventSearch :/ (qParam =: Just str <> p ))
  where
   p = maybe mempty ((pageParam =:) . Just . tshow) page

uiPagination :: DomBuilder t m => m ()
uiPagination = do
  divClass "ui pagination menu" $ do
    divClass "item" blank

txTable
  :: (DomBuilder t m, Prerender js t m,
      RouteToUrl (R FrontendRoute) m, SetRoute t (R FrontendRoute) m)
  => NetId
  -> [TxSummary]
  -> m ()
txTable _ [] = blank
txTable net txs = do
  elClass "table" "ui compact celled table" $ do
    el "thead" $ el "tr" $ do
      el "th" $ text "Status"
      el "th" $ text "Chain"
      el "th" $ text "Height"
      elClass "th" "two wide" $ text "Sender"
      el "th" $ text "Request Key"
    el "tbody" $ do
      forM_ txs $ \tx -> el "tr" $ do
        let chain = _txSummary_chain tx
        let height = _txSummary_height tx
        let status = case _txSummary_result tx of
                       TxSucceeded -> elAttr "i" ("class" =: "green check icon" <> "title" =: "Succeeded") blank
                       TxFailed -> elAttr "i" ("class" =: "red close icon" <> "title" =: "Failed") blank
                       TxUnexpected -> elAttr "i" ("class" =: "question icon" <> "title" =: "Unknown") blank
        elAttr "td" ("class" =: "center aligned" <> "data-label" =: "Status") status
        elAttr "td" ("data-label" =: "Chain") $ text $ tshow chain
        elAttr "td" ("data-label" =: "Height") $ blockLink net (ChainId chain) height $ tshow height
        elAttr "td" ("data-label" =: "Sender") $ senderWidget tx
        elAttr "td" ("data-label" =: "Request Key") $ do
          let contents = case (_txSummary_code tx, _txSummary_continuation tx) of
                           (Just _, _) -> _txSummary_requestKey tx
                           (_, Just v) -> showCont v
                           (_, _) -> ""
          text contents


evTable
  :: (DomBuilder t m, Prerender js t m,
      RouteToUrl (R FrontendRoute) m, SetRoute t (R FrontendRoute) m)
  => NetId
  -> [EventDetail]
  -> m ()
evTable _ [] = text "hi"
evTable net evs = do
  elClass "table" "ui compact celled table" $ do
    el "thead" $ el "tr" $ do
      el "th" $ text "Chain"
      el "th" $ text "Height"
      el "th" $ text "Event"
    el "tbody" $ do
      forM_ evs $ \ev -> el "tr" $ do
        let chain = _evDetail_chain ev
        let height = _evDetail_height ev
        elAttr "td" ("data-label" =: "Chain") $ text $ tshow chain
        elAttr "td" ("data-label" =: "Height") $ blockLink net (ChainId chain) height $ tshow height
        elAttr "td" ("data-label" =: "Event") $ text
            $ "("
            <> _evDetail_name ev
            <> T.intercalate " " (map tshow $ _evDetail_params ev)
            <> ")"

showCont :: AsValue s => s -> Text
showCont v = "<continuation> " <> fromMaybe "" (v ^? key "continuation" . key "def" . _String)

senderWidget :: DomBuilder t m => TxSummary -> m ()
senderWidget tx = text $
    if isPublicKey s
      then T.take 12 s <> "..."
      else if T.length s > 16
              then T.take 16 s <> "..."
              else s
  where
    s = _txSummary_sender tx
