{-|
Module      : Client.Commands.WordCompletion
Description : Tab-completion logic
Copyright   : (c) Eric Mertens, 2016
License     : ISC
Maintainer  : emertens@gmail.com

This module provides the tab-completion logic used for nicknames and channels.

-}
module Client.Commands.WordCompletion
  ( Prefix(..)
  , wordComplete

  -- * Word completion modes
  , WordCompletionMode(..)
  , plainWordCompleteMode
  , defaultNickWordCompleteMode
  , slackNickWordCompleteMode
  ) where

import qualified Client.State.EditBox as Edit
import           Control.Applicative
import           Control.Lens
import           Control.Monad
import           Data.List
import qualified Data.Set as Set
import           Data.String (IsString(..))
import qualified Data.Text as Text
import           Data.Text (Text)
import           Irc.Identifier

-- | Word completion prefix and suffix
data WordCompletionMode = WordCompletionMode
  { wcmStartPrefix, wcmStartSuffix, wcmMiddlePrefix, wcmMiddleSuffix :: String }
  deriving Show


-- | Word completion without adding any prefix or suffix
plainWordCompleteMode :: WordCompletionMode
plainWordCompleteMode = WordCompletionMode "" "" "" ""


-- | Word completion adding a ": " suffix at the beginning of lines
defaultNickWordCompleteMode :: WordCompletionMode
defaultNickWordCompleteMode = WordCompletionMode "" ": " "" ""

-- | Word completion using a "@" prefix intended
slackNickWordCompleteMode :: WordCompletionMode
slackNickWordCompleteMode = WordCompletionMode "@" " " "@" ""

-- | Perform word completion on a text box.
--
-- The leading update operation is applied to the result of tab-completion
-- when tab completing from the beginning of the text box. This is useful
-- when auto-completing a nick and including a trailing colon.
--
-- The @reversed@ parameter indicates that tab-completion should return the
-- previous entry. When starting a fresh tab completion the priority completions
-- will be considered in order before resorting to the set of possible
-- completions.
wordComplete ::
  Prefix a =>
  WordCompletionMode {- ^ leading update operation -} ->
  Bool               {- ^ reversed -} ->
  [a]       {- ^ priority completions -} ->
  [a]       {- ^ possible completions -} ->
  Edit.EditBox -> Maybe Edit.EditBox
wordComplete mode isReversed hint vals box =
  do let current = currentWord mode box
     guard (not (null current))
     let cur = fromString current
     case view Edit.lastOperation box of
       Edit.TabOperation patternStr
         | isPrefix pat cur ->

         do next <- tabSearch isReversed pat cur vals
            Just $ replaceWith mode (toString next) box
         where
           pat = fromString patternStr

       _ ->
         do next <- find (isPrefix cur) hint <|>
                    tabSearch isReversed cur cur vals
            Just $ set Edit.lastOperation (Edit.TabOperation current)
                 $ replaceWith mode (toString next) box

replaceWith :: WordCompletionMode -> String -> Edit.EditBox -> Edit.EditBox
replaceWith (WordCompletionMode spfx ssfx mpfx msfx) str box =
    let box1 = Edit.killWordBackward False box
        str1 | view Edit.pos box1 == 0 = spfx ++ str ++ ssfx
             | otherwise               = mpfx ++ str ++ msfx
    in over Edit.content (Edit.insertString str1) box1


-- | Find the word preceeding the cursor skipping over any
-- characters that can be found in the prefix and suffix for
-- the current completion mode.
currentWord :: WordCompletionMode -> Edit.EditBox -> String
currentWord (WordCompletionMode spfx ssfx mpfx msfx) box
  = dropWhile (`elem`pfx)
  $ reverse
  $ takeWhile (/= ' ')
  $ dropWhile (`elem`sfx)
  $ reverse
  $ take n txt
  where
    pfx = spfx++mpfx
    sfx = ssfx++msfx
    Edit.Line n txt = view Edit.line box

-- | Class for types that are isomorphic to 'String'
-- and which can support a total order and a prefix
-- predicate.
--
-- @
-- 'Prefix.toString' ('fromString' x) == x
-- 'fromString' ('Prefix.toString' x) == x
-- 'Prefix.isPrefix' x y ==> x '<=' y
-- @
class (IsString a, Ord a) => Prefix a where
  -- | Check if the first argument is a lexicographic prefix of the second.
  isPrefix :: a -> a -> Bool
  -- | Convert to a 'String'.
  toString :: a -> String

instance Prefix Identifier where
  isPrefix = idPrefix
  toString = Text.unpack . idText

instance Prefix Text where
  isPrefix = Text.isPrefixOf
  toString = Text.unpack


-- | Find the next entry in a list of possible choices using an alphabetical
-- ordering.
tabSearch ::
  Prefix a =>
  Bool {- ^ reversed        -} ->
  a    {- ^ search prefix   -} ->
  a    {- ^ previous result -} ->
  [a]  {- ^ posibilities    -} ->
  Maybe a
tabSearch isReversed pat cur vals
  | Set.null valSet                    = Nothing
  | Just next <- advanceFun cur valSet = Just next
  | isReversed                         = Just $! Set.findMax valSet
  | otherwise                          = Just $! Set.findMin valSet
  where
    valSet = Set.fromList (filter (isPrefix pat) vals)

    advanceFun | isReversed = Set.lookupLT
               | otherwise  = Set.lookupGT
