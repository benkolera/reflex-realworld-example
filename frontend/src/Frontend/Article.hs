{-# LANGUAGE FlexibleContexts, LambdaCase, MonoLocalBinds, MultiParamTypeClasses, OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms, RecursiveDo, ScopedTypeVariables                                      #-}

module Frontend.Article where

import Control.Lens
import Reflex.Dom.Core hiding (Element)

import           Control.Monad.Fix      (MonadFix)
import           Data.Default           (def)
import           Data.Foldable          (fold)
import           Data.Functor           (void)
import qualified Data.Map               as Map
import           Data.Maybe             (fromMaybe)
import           Data.Monoid            (Endo (Endo), appEndo)
import           Data.Text              (Text)
import qualified Data.Text.Lazy         as TL
import           GHCJS.DOM.Document     (createElement)
import           GHCJS.DOM.Element      (setInnerHTML)
import           GHCJS.DOM.Types        (liftJSM)
import qualified Lucid                  as L
import           Obelisk.Route.Frontend (pattern (:/), R, RouteToUrl, Routed, SetRoute, askRoute, routeLink)
import           Servant.Common.Req     (reqSuccess)
import qualified Text.MMark             as MMark


import qualified Common.Conduit.Api.Articles.Article       as Article
import qualified Common.Conduit.Api.Articles.Comment       as Comment
import qualified Common.Conduit.Api.Articles.CreateComment as CreateComment
import           Common.Conduit.Api.Namespace              (Namespace (..), unNamespace)
import qualified Common.Conduit.Api.Profiles.Profile       as Profile
import qualified Common.Conduit.Api.User.Account           as Account
import           Common.Route                              (DocumentSlug (..), FrontendRoute (..),
                                                            Username (..))
import           Frontend.ArticlePreview                   (profileImage, profileRoute)
import qualified Frontend.Conduit.Client                   as Client
import           Frontend.FrontendStateT
import           Frontend.Utils                            (buttonClass, routeLinkClass, routeLinkDynClass,
                                                            showText)

article
  :: forall t m js s
  .  ( DomBuilder t m
     , Prerender js t m
     , Routed t DocumentSlug m
     , SetRoute t (R FrontendRoute) m
     , RouteToUrl (R FrontendRoute) m
     , PostBuild t m
     , MonadHold t m
     , MonadFix m
     , HasFrontendState t s m
     , HasLoggedInAccount s
     )
  => m ()
article = elClass "div" "article-page" $ do
  -- We ask our route for the document slug and make the backend call on load
  slugDyn <- askRoute
  pbE <- getPostBuild
  tokDyn <- reviewFrontendState loggedInToken

  loadResE <- Client.getArticle tokDyn (pure . unDocumentSlug <$> slugDyn) pbE

  -- While we are loading, we dont have an article
  -- The types are honest about this.
  let loadSuccessE :: Event t (Maybe Article.Article) = fmap unNamespace . reqSuccess <$> loadResE

  articleDyn <- holdDyn Nothing loadSuccessE

  elClass "div" "banner" $
    elClass "div" "container" $ do
      el "h1" $ dynText $ maybe "" Article.title <$> articleDyn
      -- We are a little clumsy with dealing with not having
      -- an article. We just disply a blank element while we
      -- dont have one. Should be better. :)
      void $ dyn $ maybe blank articleMeta <$> articleDyn
  elClass "div" "container page" $ do
    articleContent articleDyn
    el "hr" blank
    elClass "div" "row article-actions" $
      void $ dyn $ maybe blank articleMeta <$> articleDyn
    elClass "div" "row" $
      elClass "div" "col-xs-12 col-md-8 offset-md-2" $ do
        -- Do the comments UI below
        comments slugDyn

articleMeta
  :: ( DomBuilder t m
     , RouteToUrl (R FrontendRoute) m
     , SetRoute t (R FrontendRoute) m
     , PostBuild t m
     , MonadHold t m
     )
  => Article.Article
  -> m ()
articleMeta art = elClass "div" "article-meta" $ do
  let profile = Article.author art
  let authorRoute = FrontendRoute_Profile :/ (Username "foo", Nothing)
  routeLink authorRoute $ profileImage "" (constDyn . Profile.image $ profile)
  elClass "div" "info" $ do
    routeLinkClass "author" authorRoute $ text (Profile.username profile)
    elClass "span" "date" $ text (showText $ Article.createdAt art)
  actions profile
  where
    actions profile = do
      -- TODO : Do something with this click
      _ <- buttonClass "btn btn-sm btn-outline-secondary action-btn" (constDyn False) $ do
        elClass "i" "ion-plus-round" blank
        text " Follow "
        text (Profile.username profile)
        text " ("
        -- TODO : Get this value
        elClass "span" "counter" $ text "0"
        text ")"
      -- TODO : Do something with this click
      text " "
      _ <- buttonClass "btn btn-sm btn-outline-primary action-btn" (constDyn False) $ do
        elClass "i" "ion-heart" blank
        text " Favourite Post ("
        elClass "span" "counter" $ text $ showText (Article.favoritesCount art)
        text ")"
      pure ()

articleContent
  :: forall t m js
  .  ( DomBuilder t m
     , Prerender js t m
     )
  => Dynamic t (Maybe Article.Article)
  -> m ()
articleContent articleDyn = prerender_ (text "Rendering Document...") $ do
  let htmlDyn = (fromMaybe "" . fmap (markDownToHtml5 . Article.body)) <$> articleDyn
  elClass "div" "row article-content" $ do
    d <- askDocument
    -- We have to sample the initial value to set it on creation
    htmlT <- sample . current $ htmlDyn
    e <- liftJSM $ do
      -- This wont execute scripts, but will allow users to XSS attack through
      -- event handling javascript attributes in any raw HTML that is let
      -- through the markdown renderer. But this is the simplest demo that
      -- mostly works. See https://github.com/qfpl/reflex-dom-template for a
      -- potentially more robust solution (we could filter out js handler attrs
      -- with something like that).
      -- It's worth noting that the react demo app does exactly what this does:
      -- https://github.com/gothinkster/react-redux-realworld-example-app/blob/master/src/components/Article/index.js#L60
      e <- createElement d ("div" :: String)
      setInnerHTML e htmlT
      pure e
    -- And make sure we update the html when the article changes
    performEvent_ $ (liftJSM . setInnerHTML e) <$> updated htmlDyn
    -- Put out raw element into our DomBuilder
    placeRawElement e

markDownToHtml5 :: Text -> Text
markDownToHtml5 t =
  case MMark.parse "" t of
    Left _  -> ""
    Right r -> TL.toStrict . L.renderText . MMark.render $ r


comments
  :: forall t m s js
  .  ( DomBuilder t m
     , SetRoute t (R FrontendRoute) m
     , RouteToUrl (R FrontendRoute) m
     , PostBuild t m
     , HasFrontendState t s m
     , HasLoggedInAccount s
     , Prerender js t m
     , MonadFix m
     , MonadHold t m
     )
  => Dynamic t DocumentSlug
  -> m ()
comments slugDyn = userWidget $ \acct -> mdo
  -- Load the comments when this widget is built
  pbE <- getPostBuild
  let tokenEDyn = constDyn . pure . Account.token $ acct
  let slugEDyn  = pure . unDocumentSlug <$> slugDyn

  loadResE <- Client.getComments tokenEDyn slugEDyn (leftmost [pbE, void $ updated slugEDyn])
  let loadSuccessE = fmapMaybe (fmap unNamespace . reqSuccess) loadResE
  -- Turn it into a map so that we have IDs for each comment
  let loadedMapE   = Map.fromList . (fmap (\c -> (Comment.id c, c))) <$> loadSuccessE

  -- Our state actually includes the AJAX load and future comment adds
  commentsMapDyn <- foldDyn appEndo Map.empty $ fold
    [ Endo . const <$> loadedMapE
    , (\newComment -> Endo $ Map.insert (Comment.id newComment) newComment) <$> newCommentE
    , ( foldMap (Endo . Map.delete) . Map.keys ) <$> deleteComment
    ]

  -- Make a form that will add a comment with the backend and return
  -- an event when they are successfully added.
  newCommentE <- elClass "form" "card comment-form" $ mdo
    commentI <- elClass "div" "card-block" $ do
      textAreaElement $ def
          & textAreaElementConfig_elementConfig.elementConfig_initialAttributes .~ Map.fromList
            [("class","form-control")
            ,("placeholder","Write a comment")
            ,("rows","3")
            ]
          & textAreaElementConfig_setValue .~ ("" <$ newE)
    let createCommentDyn = Right . Namespace <$> CreateComment.CreateComment
          <$> commentI ^. to _textAreaElement_value
    postE <- elClass "div" "card-footer" $ do
      buttonClass "btn btn-sm btn-primary" (constDyn False) $ text "Post Comment"
    submitResE <- Client.createComment tokenEDyn slugEDyn createCommentDyn postE
    let newE = fmapMaybe (fmap unNamespace . reqSuccess) submitResE
    pure newE

  -- This takes the Map Int Comment and displays them all
  deleteComment :: Event t (Map.Map Int ()) <- listViewWithKey commentsMapDyn $ \cId commentDupeDyn -> do
    -- But we have to filter out duplicate updates to prevent
    -- setting the text in unnecessarily.
    -- DISCUSS! :)
    commentDyn <- holdUniqDyn commentDupeDyn
    let profileDyn = Comment.author <$> commentDyn
    elClass "div" "card" $ do
      elClass "div" "card-block" $ do
        elClass "p" "card-text" . dynText $ Comment.body <$> commentDyn
      elClass "div" "card-footer" $ do
        let authorRouteDyn = profileRoute <$> profileDyn
        routeLinkDynClass (constDyn "comment-author") authorRouteDyn $
          profileImage "comment-author-img" (Profile.image <$> profileDyn)
        text " "
        routeLinkDynClass "comment-author" authorRouteDyn $ dynText $ Profile.username <$> profileDyn
        elClass "span" "date-posted" $ display $ Comment.createdAt <$> commentDyn
        deleteClickE <- elClass "span" "mod-options" $ do
          (trashElt,_) <- elClass' "i" "ion-trash-a" blank
          pure $ domEvent Click trashElt
        deleteResE <- Client.deleteComment tokenEDyn slugEDyn (constDyn . pure $ cId) deleteClickE
        pure $ fmapMaybe (void . reqSuccess) deleteResE
  pure ()
