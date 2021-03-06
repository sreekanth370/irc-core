{-# Language GADTs #-}

{-|
Module      : Client.Commands.Arguments.Parser
Description : Interpret argument specifications as a parser
Copyright   : (c) Eric Mertens, 2017
License     : ISC
Maintainer  : emertens@gmail.com

-}

module Client.Commands.Arguments.Parser (parse) where

import Client.Commands.Arguments.Spec
import Control.Applicative
import Control.Monad
import Control.Monad.Trans.State
import Control.Monad.Trans.Class
import Control.Applicative.Free

------------------------------------------------------------------------
-- Parser

parse :: r -> Args r a -> String -> Maybe a
parse env spec str =
  do (a,rest) <- runStateT (parseArgs env spec) str
     guard (all (' '==) rest)
     return a

type Parser = StateT String Maybe

parseArgs :: r -> Args r a -> Parser a
parseArgs env spec = runAp (parseArg env) spec

parseArg :: r -> Arg r a -> Parser a
parseArg env spec =
  case spec of
    Argument shape _ f ->
      do t <- argumentString shape
         lift (f env t)
    Optional subspec -> optional (parseArgs env subspec)
    Extension _ parseFormat ->
      do t <- token
         subspec <- lift (parseFormat env t)
         parseArgs env subspec

argumentString :: ArgumentShape -> Parser String
argumentString TokenArgument     = token
argumentString RemainingArgument = remaining

remaining :: Parser String
remaining =
  do xs <- get
     put ""
     return $! case xs of
                 ' ':xs' -> xs'
                 _       -> xs

token :: Parser String
token =
  do xs <- get
     let (t, xs') = break (' '==) (dropWhile (' '==) xs)
     guard (not (null t))
     put xs'
     return t
