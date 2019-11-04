{-|
Module      : Morloc.Pools.Pools
Description : Generate language-specific code
Copyright   : (c) Zebulun Arendsee, 2018
License     : GPL-3
Maintainer  : zbwrnz@gmail.com
Stability   : experimental
-}
module Morloc.Pools.Pools
  ( generate
  ) where

import Morloc.Namespace
import qualified Data.Map.Strict as Map
import qualified Morloc.Language as ML
import qualified Morloc.Monad as MM
import qualified Morloc.Pools.Template.C as C
import qualified Morloc.Pools.Template.Cpp as Cpp
import qualified Morloc.Pools.Template.Python3 as Py3
import qualified Morloc.Pools.Template.R as RLang

generate :: [Manifold] -> Map.Map Lang SerialMap -> MorlocMonad [Script]
generate manifolds packMaps = do
  let langs = nub . map mLang $ manifolds
  mapM (generateLang manifolds packMaps) langs

-- | If you want to add a new language, this is the function you currently need
-- to modify. Add a case for the new language name, and then the function that
-- will generate the code for a script in that language.
generateLang ::
     [Manifold] -> Map.Map Lang SerialMap -> Lang -> MorlocMonad Script
generateLang manifolds packMaps lang =
  case Map.lookup lang packMaps of
    Nothing ->
      MM.throwError . CallTheMonkeys $
      "serial map should have been initialized for all languages"
    (Just p) -> generateLang' manifolds p lang

generateLang' :: [Manifold] -> SerialMap -> Lang -> MorlocMonad Script
generateLang' ms p RLang = RLang.generate ms p
generateLang' ms p Python3Lang = Py3.generate ms p
generateLang' ms p CLang = C.generate ms p
generateLang' ms p CppLang = Cpp.generate ms p
generateLang' _ _ MorlocLang =
  MM.throwError . GeneratorError $ "Too meta, don't generate morloc code"
generateLang' _ _ x =
  MM.throwError . GeneratorError $ ML.showLangName x <> " is not yet supported"
