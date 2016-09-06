{-|
Module      : Client.Image.StatusLine
Description : Renderer for status line
Copyright   : (c) Eric Mertens, 2016
License     : ISC
Maintainer  : emertens@gmail.com

This module provides image renderers used to construct
the status image that sits between text input and the message
window.

-}
module Client.Image.StatusLine
  ( statusLineImage
  ) where

import           Client.Configuration
import           Client.Image.Palette
import           Client.State
import           Client.State.Channel
import           Client.State.Focus
import           Client.State.Network
import           Client.State.Window
import           Control.Lens
import qualified Data.Map.Strict as Map
import           Data.Text (Text)
import qualified Data.Text as Text
import           Graphics.Vty.Image
import           Irc.Identifier (Identifier, idText)
import           Numeric

-- | Renders the status line between messages and the textbox.
statusLineImage :: ClientState -> Image
statusLineImage st
  = activityBar <->
    content <|> charFill defAttr '─' fillSize 1
  where
    fillSize = max 0 (view clientWidth st - imageWidth content)
    (activitySummary, activityBar) = activityImages st
    content = horizCat
      [ myNickImage st
      , focusImage st
      , activitySummary
      , detailImage st
      , scrollImage st
      , latencyImage st
      ]


scrollImage :: ClientState -> Image
scrollImage st
  | 0 == view clientScroll st = emptyImage
  | otherwise = horizCat
      [ string defAttr "─("
      , string attr "scroll"
      , string defAttr ")"
      ]
  where
    attr = view (clientConfig . configPalette . palLabel) st

latencyImage :: ClientState -> Image
latencyImage st
  | Just network <- views clientFocus focusNetwork st
  , Just cs      <- preview (clientConnection network) st =
  case view csPingStatus cs of
    PingNever -> emptyImage
    PingSent {} -> infoBubble (string (view palLatency pal) "sent")
    PingLatency delta ->
      infoBubble (string (view palLatency pal) (showFFloat (Just 2) delta "s"))
    PingConnecting n _ ->
      infoBubble (string (view palLabel pal) "connecting" <|> retryImage)
      where
        retryImage
          | n > 0 = string defAttr ": " <|>
                    string (view palLabel pal) ("retry " ++ show n)
          | otherwise = emptyImage
  | otherwise = emptyImage
  where
    pal = view (clientConfig . configPalette) st

infoBubble :: Image -> Image
infoBubble img = string defAttr "─(" <|> img <|> string defAttr ")"

detailImage :: ClientState -> Image
detailImage st
  | view clientDetailView st = infoBubble (string attr "detail")
  | otherwise = emptyImage
  where
    attr = view (clientConfig . configPalette . palLabel) st

activityImages :: ClientState -> (Image, Image)
activityImages st = (summary, activityBar)
  where
    activityBar
      | view clientActivityBar st = activityBar' <|> activityFill
      | otherwise                 = emptyImage

    summary
      | null indicators = emptyImage
      | otherwise       = string defAttr "─[" <|>
                          horizCat indicators <|>
                          string defAttr "]"

    activityFill = charFill defAttr '─'
                        (max 0 (view clientWidth st - imageWidth activityBar'))
                        1

    activityBar' = foldr baraux emptyImage
                 $ zip winNames
                 $ Map.toList
                 $ view clientWindows st

    baraux (i,(focus,w)) rest
      | n == 0 = rest
      | otherwise = string defAttr "─[" <|>
                    char (view palWindowName pal) i <|>
                    char defAttr              ':' <|>
                    text' (view palLabel pal) focusText <|>
                    char defAttr              ':' <|>
                    string attr               (show n) <|>
                    string defAttr "]" <|> rest
      where
        n   = view winUnread w
        pal = view (clientConfig . configPalette) st
        attr | view winMention w = view palMention pal
             | otherwise         = view palActivity pal
        focusText =
          case focus of
            Unfocused           -> Text.pack "*"
            NetworkFocus net    -> net
            ChannelFocus _ chan -> idText chan

    windows     = views clientWindows Map.elems st
    windowNames = view (clientConfig . configWindowNames) st
    winNames    = Text.unpack windowNames ++ repeat '?'

    indicators  = foldr aux [] (zip winNames windows)
    aux (i,w) rest
      | view winUnread w == 0 = rest
      | otherwise = char attr i : rest
      where
        pal = view (clientConfig . configPalette) st
        attr | view winMention w = view palMention pal
             | otherwise         = view palActivity pal


myNickImage :: ClientState -> Image
myNickImage st =
  case view clientFocus st of
    NetworkFocus network      -> nickPart network Nothing
    ChannelFocus network chan -> nickPart network (Just chan)
    Unfocused                 -> emptyImage
  where
    pal = view (clientConfig . configPalette) st
    nickPart network mbChan =
      case preview (clientConnection network) st of
        Nothing -> emptyImage
        Just cs -> string (view palSigil pal) myChanModes
               <|> text' defAttr (idText nick)
               <|> parens defAttr (string defAttr ('+' : view csModes cs))
               <|> char defAttr '─'
          where
            nick      = view csNick cs
            myChanModes =
              case mbChan of
                Nothing   -> []
                Just chan -> view (csChannels . ix chan . chanUsers . ix nick) cs


focusImage :: ClientState -> Image
focusImage st = parens defAttr majorImage <|> renderedSubfocus
  where
    majorImage = horizCat
      [ char (view palWindowName pal) windowName
      , char defAttr ':'
      , renderedFocus
      ]

    pal = view (clientConfig . configPalette) st
    focus = view clientFocus st
    windowNames = view (clientConfig . configWindowNames) st

    windowName =
      case Map.lookupIndex focus (view clientWindows st) of
        Just i | i < Text.length windowNames -> Text.index windowNames i
        _ -> '?'

    subfocusName =
      case view clientSubfocus st of
        FocusMessages -> Nothing
        FocusWindows  -> Just $ string (view palLabel pal) "windows"
        FocusInfo     -> Just $ string (view palLabel pal) "info"
        FocusUsers    -> Just $ string (view palLabel pal) "users"
        FocusMentions -> Just $ string (view palLabel pal) "mentions"
        FocusPalette  -> Just $ string (view palLabel pal) "palette"
        FocusHelp mb  -> Just $ string (view palLabel pal) "help" <|>
                                foldMap (\cmd -> char defAttr ':' <|>
                                            text' (view palLabel pal) cmd) mb
        FocusMasks m  -> Just $ horizCat
          [ string (view palLabel pal) "masks"
          , char defAttr ':'
          , char (view palLabel pal) m
          ]

    renderedSubfocus =
      foldMap (\name -> horizCat
          [ string defAttr "─("
          , name
          , char defAttr ')'
          ]) subfocusName

    renderedFocus =
      case focus of
        Unfocused ->
          char (view palError pal) '*'
        NetworkFocus network ->
          text' (view palLabel pal) network
        ChannelFocus network channel ->
          text' (view palLabel pal) network <|>
          char defAttr ':' <|>
          text' (view palLabel pal) (idText channel) <|>
          channelModesImage network channel st

channelModesImage :: Text -> Identifier -> ClientState -> Image
channelModesImage network channel st =
  case preview (clientConnection network . csChannels . ix channel . chanModes) st of
    Just modeMap | not (null modeMap) ->
        string defAttr (" +" ++ modes) <|>
        horizCat [ char defAttr ' ' <|> text' defAttr arg | arg <- args, not (Text.null arg) ]
      where (modes,args) = unzip (Map.toList modeMap)
    _ -> emptyImage

parens :: Attr -> Image -> Image
parens attr i = char attr '(' <|> i <|> char attr ')'
