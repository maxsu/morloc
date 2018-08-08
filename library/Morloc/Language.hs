{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE MultiWayIf #-}

{-|
Module      : Morloc.Language
Description : Language-specific grammar templates for code generation
Copyright   : (c) Zebulun Arendsee, 2018
License     : GPL-3
Maintainer  : zbwrnz@gmail.com
Stability   : experimental
-}

module Morloc.Language (
    CodeGenerator(..)
  , rCodeGenerator
) where

import qualified Data.Text as DT
import qualified Data.Aeson as DA
import qualified Data.HashMap.Strict as DHS
import qualified Data.Vector as DV

import Morloc.Operators
import qualified Morloc.Util as MU

data CodeGenerator = CodeGenerator {
      -- | The top level pool constructor for the given language
      makePool
        :: [DT.Text] --   any required global declarations
        -> [DT.Text] --   any input source code
        -> [DT.Text] --   the node function declarations
        -> DT.Text   --   entire pool script

    -- | Generator of importing source code
    , makeSource
        :: DT.Text --   path
        -> DT.Text

    -- | Generator for building a function call
    , makeCall
        :: DT.Text   --   function name
        -> [DT.Text] --   arguments
        -> DT.Text

    -- | Generator for building a function
    , makeFunction
        :: DT.Text   --   function name
        -> [DT.Text] --   function arguments
        -> DT.Text   --   function body
        -> DT.Text

    -- | Generator for building a manifold name from some base name
    , makeManifoldName
        :: DT.Text --   RDF unique ID (e.g. "mid:42")
        -> DT.Text

    , makeData
        :: DA.Value --   Literal data from the Morloc script
        -> DT.Text
  }

-- | An experimental generator for the R language
rCodeGenerator :: CodeGenerator
rCodeGenerator = CodeGenerator {
      makePool     = makePool'
    , makeSource   = makeSource'
    , makeCall     = makeCall'
    , makeFunction = makeFunction'
    , makeManifoldName = makeManifoldName'
    , makeData = makeData'
  }
  where

    makePool' :: [DT.Text] -> [DT.Text] -> [DT.Text] -> DT.Text
    makePool' gs is fs = DT.unlines . concat $ [begin', gs, is, fs, end']

    makeSource' :: DT.Text -> DT.Text 
    makeSource' path = "source(\"" <> path <> "\")"

    makeCall' :: DT.Text -> [DT.Text] -> DT.Text
    makeCall' fname args = fname <> "(" <> DT.intercalate ", " args <> ")" 

    makeFunction' :: DT.Text -> [DT.Text] -> DT.Text -> DT.Text
    makeFunction' name args body
      =  name <> " <- function (" <> DT.intercalate ", " args <> ")"
      <> "{\n" <> MU.indent 2 body <> "}\n"

    makeManifoldName' :: DT.Text -> DT.Text
    makeManifoldName' t = case DT.splitOn ":" t of
      [_, i] -> "m" <> i
      _ -> error "R generator error: unexpected manifold ID"

    makeData' :: DA.Value -> DT.Text
    makeData' (DA.Object x) = case DHS.toList x of
      [("List", DA.Array l)] -> case findCaster (DV.toList l) of
        (Just caster) -> caster <> "("
          <> "c(" <> DT.intercalate ", " (map makeData' (DV.toList l)) <> ")" 
          <> ")"
        Nothing -> error "Heterogenous lists are not supported" 
      [("Tuple", x)] -> makeData' x 
      xs -> "list("
         <> DT.intercalate ", " (map (\(k, v) -> k <> " = " <> makeData' v) xs)
         <> ")"
    makeData' (DA.Array xs) = "list(" <> DT.intercalate ", " (map makeData' (DV.toList xs)) <> ")"
    makeData' (DA.String x) = x
    makeData' (DA.Number x) = DT.pack (show x)
    makeData' (DA.Bool True) = "True"
    makeData' (DA.Bool False) = "False"
    makeData' DA.Null = "NULL"

    findCaster :: [DA.Value] -> Maybe DT.Text
    -- Either it is a single primitive value
    findCaster [DA.Number _] = Just "as.numeric"
    findCaster [DA.Bool   _] = Just "as.logical"
    findCaster [DA.String _] = Just "as.character"
    -- Or it is a list of the same primitive values
    findCaster (DA.Number _:(DA.Number y:xs)) = findCaster (DA.Number y:xs)
    findCaster (DA.Bool   _:(DA.Bool   y:xs)) = findCaster (DA.Bool   y:xs)
    findCaster (DA.String _:(DA.String y:xs)) = findCaster (DA.String y:xs)
    findCaster _ = Nothing

    begin' = ["#!/usr/bin/env Rscript"]

    end'   =
      [ "args <- commandArgs(trailingOnly=TRUE)"
      , "if(length(args) == 0){"
      , "  stop(\"Expected 1 or more arguments\")"
      , "} else if(exists(args[[1]])){"
      , "  x <- get(args[[1]])"
      , "  result <- if(class(x) == \"function\"){"
      , "    par <- lapply(args[-1], function(s) eval(parse(text=s)))"
      , "    do.call(get(args[[1]]), par)"
      , "  } else {"
      , "    x"
      , "  }"
      , "  cat(result, \"\\n\")"
      , "} else {"
      , "  stop(\"Could not find function '\", args[[1]], \"'\")"
      , "}"
      ]
