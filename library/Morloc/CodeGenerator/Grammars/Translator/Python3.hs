{-# LANGUAGE TemplateHaskell, QuasiQuotes #-}

{-|
Module      : Morloc.CodeGenerator.Grammars.Translator.Python3
Description : Python3 translator
Copyright   : (c) Zebulun Arendsee, 2020
License     : GPL-3
Maintainer  : zbwrnz@gmail.com
Stability   : experimental
-}

module Morloc.CodeGenerator.Grammars.Translator.Python3
  ( 
    translate
  ) where

import Morloc.Namespace
import Morloc.CodeGenerator.Grammars.Common
import Morloc.Data.Doc
import Morloc.Quasi

translate :: [Source] -> [Manifold] -> MorlocMonad MDoc
translate srcs ms = do 
  let includes = unique . catMaybes . map srcPath $ srcs

  lib <- return "lib"
  includeDocs <- mapM translateSource includes
  mDocs <- mapM translateManifold ms
  dispatch <- makeDispatch ms
  return $ makePool lib includeDocs mDocs dispatch

translateSource :: Path -> MorlocMonad MDoc
translateSource p = return $ pretty p

translateManifold :: Manifold -> MorlocMonad MDoc
translateManifold _ = return "manifold"

makeDispatch :: [Manifold] -> MorlocMonad MDoc
makeDispatch _ = return "DISPATCH"

makePool :: MDoc -> [MDoc] -> [MDoc] -> MDoc -> MDoc
makePool lib includeDocs manifolds dispatch = [idoc|#!/usr/bin/env python

import sys
import subprocess
import json

sys.path = ["#{lib}"] + sys.path

#{vsep includeDocs}

def _morloc_unpack(unpacker, jsonString, mid, filename):
    try:
        pyObj = unpacker(jsonString)
    except Exception:
        msg = "Error in %s::%s - JSON parse failure" % (filename, mid)
        if(len(jsonString) == 0):
            msg += ": empty document"
        else:
            msg += ", bad document:\n%s" % str(jsonString)
        sys.exit(msg)
    return(pyObj)

def _morloc_foreign_call(interpreter, pool, mid, args):
    try:
        sysObj = subprocess.run(
            [interpreter, pool, mid, *args],
            capture_output=True,
            check=True,
            encoding="ascii"
        )
    except subprocess.CalledProcessError as e:
        sys.exit(str(e))

    jsonString = sysObj.stdout
    jsonLog = sysObj.stderr

    if(len(jsonLog) > 0):
      print(jsonLog, file=sys.stderr)

    return(jsonString)

#{vsep manifolds}

if __name__ == '__main__':
    try:
        cmdID = int(sys.argv[1])
    except IndexError:
        sys.exit("Internal error in {}: no manifold id found".format(sys.argv[0]))
    except ValueError:
        sys.exit("Internal error in {}: expected integer manifold id".format(sys.argv[0]))
    try:
    #{dispatch}
    except KeyError:
        sys.exit("Internal error in {}: no manifold found with id={}".format(sys.argv[0], cmdID))

    print(result)
|]
