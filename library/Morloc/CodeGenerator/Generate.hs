{-|
Module      : Morloc.CodeGenerator.Generate
Description : Short description
Copyright   : (c) Zebulun Arendsee, 2020
License     : GPL-3
Maintainer  : zbwrnz@gmail.com
Stability   : experimental
-}

module Morloc.CodeGenerator.Generate
(
  generate
) where

import Morloc.Namespace
import Morloc.Data.Doc
import Morloc.TypeChecker.PartialOrder
import Morloc.Pretty (prettyType, prettyExpr)
import qualified Morloc.Config as MC
import qualified Morloc.Data.Text as MT
import qualified Morloc.Language as Lang
import qualified Morloc.Monad as MM
import Morloc.CodeGenerator.Grammars.Common
import qualified Morloc.CodeGenerator.Nexus as Nexus
import qualified Morloc.System as MS
import Data.Scientific (Scientific)
import qualified Data.Map as Map
import qualified Data.Set as Set

import qualified Morloc.CodeGenerator.Grammars.Translator.Cpp as Cpp
import qualified Morloc.CodeGenerator.Grammars.Translator.R as R
import qualified Morloc.CodeGenerator.Grammars.Translator.Python3 as Python3

-- | Store all necessary information about a particular implementation of a
-- term.  A term may either be declared or sourced. If declared, the left and
-- right hand sides of the declaration are stored. If sourced, the Source
-- object is stored. In either case, the module where the term is defined is
-- also stored.
data TermOrigin = Declared Module EVar Expr | Sourced Module Source
  deriving(Show, Ord, Eq)

-- | Translate typechecker-created modules into compilable code
generate :: [Module] -> MorlocMonad (Script, [Script])
generate ms = do
  -- initialize state counter to 0, used to index manifolds
  MM.startCounter

  -- modmap :: Map.Map MVar Module
  let modmap = Map.fromList [(moduleName m, m) | m <- ms]

  -- translate modules into bitrees
  (gASTs, rASTs) 
    -- find each term that is exported to the nexus
    <- roots modmap   -- [(EVar, [TermOrigin])]
    -- turn each term into an ambiguous call tree
    >>= mapM (collect modmap)   -- [SAnno GMeta Many [CType]]
    -- eliminate morloc composition abstractions
    >>= mapM rewrite
    -- select a single instance at each node in the tree
    >>= mapM realize   -- [Either (SAnno GMeta One CType) (SAnno GMeta One CType)]
    -- separate unrealized (general) ASTs (uASTs) from realized ASTs (rASTs)
    |>> partitionEithers

  -- -- print abstract syntax trees to the console as debugging message
  -- say $ line <> indent 2 (vsep (map (writeAST id Nothing) rASTs))
  
  -- Collect all call-free data
  gSerial <- mapM generalSerial gASTs
  
  -- build nexus
  -- -----------
  -- Each nexus subcommand calls one function from one one pool.
  -- The call passes the pool an index for the function (manifold) that will be called.
  nexus <- Nexus.generate
    gSerial
    [ (t, poolId m x, metaName m)
    | SAnno (One (x, t)) m <- rASTs
    ]

  -- find all sources files
  let srcs = unique . concat $ map (map snd . Map.assocs . moduleSourceMap) ms

  -- for each language, collect all functions into one "pool"
  pools
    <- mapM parameterize rASTs
    -- Separate the call trees into mono-lingual segments terminated in
    -- primitives or foreign calls.
    >>= mapM segment |>> concat
    -- Gather segments into pools, currently tihs entails gathering all
    -- segments from a given language into one pool. Later it may be more
    -- nuanced.
    >>= pool
    -- Generate the code for each pool
    >>= mapM (encode srcs)

  -- return the nexus script and each pool script
  return (nexus, pools)
  where
    -- map from nexus id to pool id
    -- these differ when a declared variable is exported
    poolId :: GMeta -> SExpr GMeta One CType -> Int
    poolId _ (LamS _ (SAnno _ meta)) = metaId meta
    poolId meta _ = metaId meta

-- | Find the expressions that are exposed to the user.
-- Each element of the returned list consists of an EVar that is the term
-- exported from the main module. This term may be a named composition in the
-- main module, a sourced function/value from language-specific code, or an
-- imported term from another module. A term may be defined in multiple modules
-- or sourced from multiple implementations. Thus each term exported from main
-- is associated with a list of possible implementations/realizations.
roots :: Map.Map MVar Module -> MorlocMonad [(EVar, [TermOrigin])]
roots ms = do
  xs <- case roots of
    [m] ->
      let vs = Set.toList (moduleExports m) in
        return $ zip vs (map (findTerm False ms m) vs)
    [] -> MM.throwError CyclicDependency
    _ -> MM.throwError . GeneratorError $ "Multiple root modules"

  return xs
  where
    isRoot m = not $ Set.member (moduleName m) allImports
    allImports = mapSumWith (valset . moduleImportMap) ms
    roots = filter isRoot (Map.elems ms)


-- | Build the call tree for a single nexus command. The result is ambiguous,
-- with 1 or more possible tree topologies, each with one or more possible for
-- each function.
collect
  :: Map.Map MVar Module
  -> (EVar, [TermOrigin])
  -> MorlocMonad (SAnno GMeta Many [CType])
collect ms (v, []) = MM.throwError . GeneratorError $
  "No origin found for variable '" <> unEVar v <> "'"
collect ms (evar', xs@(x:_)) = do
  -- Just look at one x, since any should emit the same GMeta (if not, then
  -- something is broken upstream of GMeta is not general enough)
  gmeta <- makeGMeta (Just evar') (getTermModule x) Nothing
  trees <- mapM collectTerm xs
  return $ SAnno (Many trees) gmeta
  where

    -- Notice that `args` is NOT an input to collectTerm. Morloc uses lexical
    -- scoping, and the input to collectTerm is the origin of a term, so the
    -- definition of the term is outside the scope of the parent expression.
    collectTerm
      :: TermOrigin
      -> MorlocMonad (SExpr GMeta Many [CType], [CType])
    collectTerm (Declared m _ (AnnE x ts)) = do
      xs <- collectExpr Set.empty m (getCTypes ts) x
      case xs of
        [x] -> return x
        _ -> MM.throwError . GeneratorError $
          "Expected exactly one topology for a declared term"
    collectTerm (Declared _ _ _) = MM.throwError . GeneratorError $
      "Invalid expression in CollectTerm Declared, expected AnnE"
    collectTerm term@(Sourced m src) = do
      ts <- getTermTypes term |>> getCTypes
      return (CallS src, ts)
      where
        getTermTypes :: TermOrigin -> MorlocMonad [Type]
        getTermTypes t = do
          (TypeSet _ es) <- getTermTypeSet t
          return $ map etype es

    collectAnno
      :: Set.Set EVar
      -> Module
      -> Expr
      -> MorlocMonad (SAnno GMeta Many [CType])
    collectAnno args m (AnnE e ts) = do
      gtype <- getGType ts
      gmeta <- makeGMeta (getExprName e) m gtype
      trees <- collectExpr args m (getCTypes ts) e
      return $ SAnno (Many trees) gmeta
    collectAnno _ _ _ = error "impossible bug - unannotated expression"

    getExprName :: Expr -> Maybe EVar
    getExprName (VarE v) = Just v
    getExprName _ = Nothing

    collectExpr
      :: Set.Set EVar
      -> Module
      -> [CType]
      -> Expr
      -> MorlocMonad [(SExpr GMeta Many [CType], [CType])]
    collectExpr args m ts (UniE) = return [(UniS, ts)]
    collectExpr args m ts (NumE x) = return [(NumS x, ts)]
    collectExpr args m ts (LogE x) = return [(LogS x, ts)]
    collectExpr args m ts (StrE x) = return [(StrS x, ts)]
    collectExpr args m ts (VarE v)
      | Set.member v args = return [(VarS v, ts)]
      | otherwise = do
          let terms = findTerm True ms m v
          xs <- mapM collectTerm terms
          let chosen = map (chooseTypes ts) xs
          return chosen
      where
        -- FIXME: The typesystem should handle this. It should unroll every
        -- type as far as it can be unrolled, and infer specialized types all
        -- the way down. Multiple declarations of every term within a given
        -- language should be allowed. The function below will only work in
        -- special cases where there is A) a single instance of the term in
        -- each language and B) types beneath the term (if this is a
        -- composition) do not depend on the type on top.
        chooseTypes
          :: [CType]
          -> (SExpr GMeta Many [CType], [CType])
          -> (SExpr GMeta Many [CType], [CType])
        chooseTypes ts (x, ts') =
          (x, [ t
              | t <- ts
              , t' <- ts'
              , langOf' t == langOf' t'])
    collectExpr args m ts (ListE es) = do
      es' <- mapM (collectAnno args m) es
      return [(ListS es', ts)]
    collectExpr args m ts (TupleE es) = do
      es' <- mapM (collectAnno args m) es
      return [(TupleS es', ts)]
    collectExpr args m ts (RecE entries) = do
      es' <- mapM (collectAnno args m) (map snd entries)
      let entries' = zip (map fst entries) es'
      return [(RecS entries', ts)]
    collectExpr args m ts e@(LamE v x) =
      case unrollLambda e of
        (args', e') -> do
          -- say $ "in LamE:" <+> prettyExpr x
          e'' <- collectAnno (Set.union args (Set.fromList args')) m e'
          return [(LamS args' e'', ts)]
    -- AppS (SAnno g f c) [SAnno g f c]
    collectExpr args m ts (AppE e1 e2) = do
      -- say $ "in AppE:" <+> parens (prettyExpr e1) <+> parens (prettyExpr e2)
      -- The topology of e1' may vary. It could be a direct binary function. Or
      -- it could be a partially applied function. So it is necessary to map
      -- over the Many.
      e1'@(SAnno (Many fs) g1) <- collectAnno args m e1
      e2' <- collectAnno args m e2
      -- say $ "in AppE e1':" <+> writeManyAST e1'
      -- say $ "in AppE e2':" <+> writeManyAST e2'
      mapM (app g1 e2') fs

    collectExpr _ _ _ _ = MM.throwError . GeneratorError $
      "Unexpected expression in collectExpr"
    app
      :: GMeta
      -> SAnno GMeta Many [CType]
      -> (SExpr GMeta Many [CType], [CType])
      -> MorlocMonad (SExpr GMeta Many [CType], [CType])
    app _ e2 ((AppS f es), ts) = do
      ts' <- mapM partialApplyConcrete ts
      return (AppS f (es ++ [e2]), ts')
    app g e2 (f, ts) = do
      ts' <- mapM partialApplyConcrete ts
      return (AppS (SAnno (Many [(f, ts)]) g) [e2], ts')

    partialApplyConcrete :: CType -> MorlocMonad CType
    partialApplyConcrete t =
      fmap CType $ partialApply (unCType t)

-- | Find info common across realizations of a given term in a given module
makeGMeta :: Maybe EVar -> Module -> Maybe GType -> MorlocMonad GMeta
makeGMeta name m gtype = do
  i <- MM.getCounter
  case name >>= (flip Map.lookup) (moduleTypeMap m) of
    (Just (TypeSet (Just e) _)) -> do
      return $ GMeta
        { metaId = i
        , metaName = name
        , metaGType = maybe (Just . GType $ etype e) Just gtype
        , metaProperties = eprop e
        , metaConstraints = econs e
        }
    _ -> do
      return $ GMeta
        { metaId = i
        , metaName = name
        , metaGType = gtype
        , metaProperties = Set.empty
        , metaConstraints = Set.empty
        }

-- | Eliminate morloc function calls
-- For example:
--    foo x y = bar x (baz y)
--    bar x y = add x y
--    baz x = div x 5
-- Can be rewritten as:
--    foo x y = add x (div y 5)
-- Notice that no morloc abstractions appear on the right hand side.
rewrite
  :: SAnno GMeta Many [CType]
  -> MorlocMonad (SAnno GMeta Many [CType])
rewrite (SAnno (Many es0) g0) = do
  es0' <- fmap concat $ mapM rewriteL0 es0 
  return $ SAnno (Many es0') g0
  where
    rewriteL0
      :: (SExpr GMeta Many [CType], [CType])
      -> MorlocMonad [(SExpr GMeta Many [CType], [CType])]
    rewriteL0 (AppS (SAnno (Many es1) g1) args, c1) = do
      args' <- mapM rewrite args
      -- originally es1 consists of a list of CallS and LamS constructors
      --  - CallS are irreducible source functions
      --  - LamS are Morloc abstractions that can be reduced
      -- separate LamS expressions from all others
      let (es1LamS, es1CallS) = partitionEithers (map sepLamS es1)
      -- rewrite the LamS expressions, each expression will yields 1 or more
      es1LamS' <- fmap concat $ mapM (rewriteL1 args') es1LamS
      return $ (AppS (SAnno (Many es1CallS) g1) args', c1) : es1LamS'
      where
        sepLamS
          :: (SExpr g Many c, c)
          -> Either ([EVar], SAnno g Many c)
                    (SExpr g Many c, c)
        sepLamS (x@(LamS vs body), _) = Left (vs, body)
        sepLamS x = Right x
    rewriteL0 (ListS xs, c) = do
      xs' <- mapM rewrite xs
      return [(ListS xs', c)]
    rewriteL0 (TupleS xs, c) = do
      xs' <- mapM rewrite xs
      return [(TupleS xs', c)]
    rewriteL0 (RecS entries, c) = do
      xs' <- mapM rewrite (map snd entries)
      return [(RecS $ zip (map fst entries) xs', c)]
    rewriteL0 (LamS vs x, c) = do
      x' <- rewrite x
      return [(LamS vs x', c)]
    -- VarS UniS NumS LogS StrS CallS ForeignS
    rewriteL0 x = return [x]

    rewriteL1
      :: [SAnno g Many c]
      -> ([EVar], SAnno g Many c) -- lambda variables and body
      -> MorlocMonad [(SExpr g Many c, c)]
    rewriteL1 args (vs, SAnno (Many es2) g2)
      | length vs == length args =
          fmap concat $ mapM (substituteExprs (zip vs args)) es2
      | length vs > length args = MM.throwError . NotImplemented $
          "Partial function application not yet implemented (coming soon)"
      | length vs < length args = MM.throwError . TypeError $
          "Type error: too many arguments applied to lambda"

    substituteExprs
      :: [(EVar, SAnno g Many c)]
      -> (SExpr g Many c, c) -- body
      -> MorlocMonad [(SExpr g Many c, c)] -- substituted bodies
    substituteExprs [] x = return [x]
    substituteExprs ((v, r):rs) x = do
      xs' <- substituteExpr v r x
      fmap concat $ mapM (substituteExprs rs) xs'

    substituteExpr
      :: EVar
      -> SAnno g Many c -- replacement
      -> (SExpr g Many c, c) -- expression
      -> MorlocMonad [(SExpr g Many c, c)]
    substituteExpr v (SAnno (Many xs) _) x@(VarS v', _)
      | v == v' = return xs
      | otherwise = return [x]
    substituteExpr v r (ListS xs, c) = do
      xs' <- mapM (substituteAnno v r) xs
      return [(ListS xs, c)]
    substituteExpr v r (TupleS xs, c) = do
      xs' <- mapM (substituteAnno v r) xs
      return [(TupleS xs, c)]
    substituteExpr v r (RecS entries, c) = do
      xs' <- mapM (substituteAnno v r) (map snd entries)
      return [(RecS (zip (map fst entries) xs'), c)]
    substituteExpr v r (LamS vs x, c) = do
      x' <- substituteAnno v r x
      return [(LamS vs x', c)]
    substituteExpr v r (AppS f xs, c) = do
      f' <- substituteAnno v r f
      xs' <- mapM (substituteAnno v r) xs
      return [(AppS f' xs', c)]
    -- UniS NumS LogS StrS CallS ForeignS
    substituteExpr _ _ x = return [x]

    substituteAnno
      :: EVar -- variable to replace
      -> SAnno g Many c -- replacement branch set
      -> SAnno g Many c -- search branch
      -> MorlocMonad (SAnno g Many c)
    substituteAnno v r (SAnno (Many xs) g) = do
      xs' <- fmap concat $ mapM (substituteExpr v r) xs
      return $ SAnno (Many xs') g

-- | Select a single concrete language for each sub-expression.  Store the
-- concrete type and the general type (if available).  Select serialization
-- functions (the serial map should not be needed after this step in the
-- workflow).
realize
  :: SAnno GMeta Many [CType]
  -> MorlocMonad (Either (SAnno GMeta One ()) (SAnno GMeta One CType))
realize x = do
  -- say $ " --- realize ---"
  -- say $ writeManyAST x
  -- say $ " ---------------"
  realizationMay <- realizeAnno 0 Nothing x
  case realizationMay of
    Nothing -> makeGAST x |>> Left
    (Just (_, realization)) -> do
       rewritePartials realization |>> Right
  where
    realizeAnno
      :: Int
      -> Maybe Lang
      -> SAnno GMeta Many [CType]
      -> MorlocMonad (Maybe (Int, SAnno GMeta One CType))
    realizeAnno depth langMay (SAnno (Many xs) m) = do
      asts <- mapM (\(x, cs) -> mapM (realizeExpr (depth+1) langMay x) cs) xs |>> concat
      case minimumOnMay (\(s,_,_) -> s) (catMaybes asts) of
        Just (i, x, c) -> do
          return $ Just (i, SAnno (One (x, c)) m)
        Nothing -> do
          return Nothing

    indent' :: Int -> MDoc
    indent' i = pretty (take i (repeat '-')) <> " "

    realizeExpr
      :: Int
      -> Maybe Lang
      -> SExpr GMeta Many [CType]
      -> CType
      -> MorlocMonad (Maybe (Int, SExpr GMeta One CType, CType))
    realizeExpr depth lang x c = do
      realizeExpr' depth (maybe (langOf' c) id lang) x c

    realizeExpr'
      :: Int
      -> Lang
      -> SExpr GMeta Many [CType]
      -> CType
      -> MorlocMonad (Maybe (Int, SExpr GMeta One CType, CType))
    -- always choose the primitive that is in the same language as the parent
    realizeExpr' _ lang (UniS) c
      | lang == langOf' c = return $ Just (0, UniS, c)
      | otherwise = return Nothing
    realizeExpr' _ lang (NumS x) c
      | lang == langOf' c = return $ Just (0, NumS x, c)
      | otherwise = return Nothing
    realizeExpr' _ lang (LogS x) c
      | lang == langOf' c = return $ Just (0, LogS x, c)
      | otherwise = return Nothing
    realizeExpr' _ lang (StrS x) c
      | lang == langOf' c = return $ Just (0, StrS x, c)
      | otherwise = return Nothing
    -- a call should also be of the same language as the parent, shouldn't it?
    realizeExpr' _ lang (CallS src) c
      | lang == langOf' c = return $ Just (0, CallS src, c)
      | otherwise = return Nothing
    -- and a var?
    realizeExpr' _ lang (VarS x) c
      | lang == langOf' c = return $ Just (0, VarS x, c)
      | otherwise = return Nothing
    -- simple recursion into ListS, TupleS, and RecS
    realizeExpr' depth lang (ListS xs) c
      | lang == langOf' c = do
        xsMay <- mapM (realizeAnno depth (Just lang)) xs
        case (fmap unzip . sequence) xsMay of
          (Just (scores, xs')) -> return $ Just (sum scores, ListS xs', c)
          Nothing -> return Nothing
      | otherwise = return Nothing
    realizeExpr' depth lang (TupleS xs) c
      | lang == langOf' c = do
        xsMay <- mapM (realizeAnno depth (Just lang)) xs
        case (fmap unzip . sequence) xsMay of
          (Just (scores, xs')) -> return $ Just (sum scores, TupleS xs', c)
          Nothing -> return Nothing
      | otherwise = return Nothing
    realizeExpr' depth lang (RecS entries) c
      | lang == langOf' c = do
          xsMay <- mapM (realizeAnno depth (Just lang)) (map snd entries)
          case (fmap unzip . sequence) xsMay of
            (Just (scores, vals)) -> return $ Just (sum scores, RecS (zip (map fst entries) vals), c)
            Nothing -> return Nothing
      | otherwise = return Nothing
    --
    realizeExpr' depth _ (LamS vs x) c = do
      xMay <- realizeAnno depth (Just $ langOf' c) x
      case xMay of
        (Just (score, x')) -> return $ Just (score, LamS vs x', c)
        Nothing -> return Nothing
    realizeExpr' depth lang (AppS f xs) c = do
      fMay <- realizeAnno depth (Just $ langOf' c) f
      xsMay <- mapM (realizeAnno depth (Just $ langOf' c)) xs
      case (fMay, (fmap unzip . sequence) xsMay, Lang.pairwiseCost lang (langOf' c)) of
        (Just (fscore, f'), Just (scores, xs'), Just interopCost) ->
          return $ Just (fscore + sum scores + interopCost, AppS f' xs', c) 
        _ -> return Nothing
    realizeExpr' _ _ (ForeignS _ _ _) _ = MM.throwError . GeneratorError $
      "ForeignS should not yet appear in an SExpr"

makeGAST :: SAnno GMeta Many [CType] -> MorlocMonad (SAnno GMeta One ())
makeGAST (SAnno (Many [(UniS, _)]) m) = return (SAnno (One (UniS, ())) m)
makeGAST (SAnno (Many [(VarS x, _)]) m) = return (SAnno (One (VarS x, ())) m)
makeGAST (SAnno (Many [(NumS x, _)]) m) = return (SAnno (One (NumS x, ())) m)
makeGAST (SAnno (Many [(LogS x, _)]) m) = return (SAnno (One (LogS x, ())) m)
makeGAST (SAnno (Many [(StrS x, _)]) m) = return (SAnno (One (StrS x, ())) m)
makeGAST (SAnno (Many [(ListS ss, _)]) m) = do
  ss' <- mapM makeGAST ss
  return $ SAnno (One (ListS ss', ())) m
makeGAST (SAnno (Many [(TupleS ss, _)]) m) = do
  ss' <- mapM makeGAST ss
  return $ SAnno (One (TupleS ss', ())) m
makeGAST (SAnno (Many [(LamS vs s, _)]) m) = do
  s' <- makeGAST s
  return $ SAnno (One (LamS vs s', ())) m
makeGAST (SAnno (Many [(AppS f xs, _)]) m) = do
  f' <- makeGAST f
  xs' <- mapM makeGAST xs
  return $ SAnno (One (AppS f' xs', ())) m
makeGAST (SAnno (Many [(RecS es, _)]) m) = do
  vs <- mapM (makeGAST . snd) es
  return $ SAnno (One (RecS (zip (map fst es) vs), ())) m
makeGAST (SAnno (Many [(CallS _, _)]) _) = MM.throwError . OtherError $ "Expected GAST"
makeGAST (SAnno (Many [(ForeignS _ _ _, _)]) _) = MM.throwError . OtherError $ "Expected GAST"
makeGAST (SAnno (Many (_:_)) _) = MM.throwError . OtherError $ "Expected GAST"


-- | Serialize a simple, general data type. This type can consists only of JSON
-- primitives and containers (lists, tuples, and records).
generalSerial :: SAnno GMeta One () -> MorlocMonad (EVar, MDoc)
generalSerial x@(SAnno _ g) = do 
  mdoc <- generalSerial' x
  case metaName g of
    (Just evar) -> return (evar, mdoc)
    Nothing -> MM.throwError . OtherError $ "No name found for call-free function"
  where
    generalSerial' :: SAnno GMeta One () -> MorlocMonad MDoc
    generalSerial' (SAnno (One (UniS, _)) _) = return "null"
    generalSerial' (SAnno (One (NumS x, _)) _) = return $ viaShow x
    generalSerial' (SAnno (One (LogS x, _)) _) = return $ if x then "true" else "false" 
    generalSerial' (SAnno (One (StrS x, _)) _) = return $ dquotes (pretty x)
    generalSerial' (SAnno (One (ListS xs, _)) _) = do
      xs' <- mapM generalSerial' xs
      return $ list xs'
    generalSerial' (SAnno (One (TupleS xs, _)) _) = do
      xs' <- mapM generalSerial' xs
      return $ list xs'
    generalSerial' (SAnno (One (RecS es, _)) _) = do
      vs' <- mapM (generalSerial' . snd) es
      let es' = zip (map fst es) vs'
      return . encloseSep "{" "}" "," $ map (\(k, v) -> pretty k <+> "=" <+> v) es'
    generalSerial' _ = MM.throwError . OtherError $ "Cannot serialize this shit"


rewritePartials
  :: SAnno GMeta One CType
  -> MorlocMonad (SAnno GMeta One CType)
rewritePartials s@(SAnno (One (AppS f xs, ftype@(CType (FunT _ _)))) m) = do
  -- say $ writeAST id Nothing s
  let gTypeArgs = maybe (repeat Nothing) typeArgsG (metaGType m)
  f' <- rewritePartials f
  xs' <- mapM rewritePartials xs
  lamGType <- makeGType $ [metaGType g | (SAnno _ g) <- xs'] ++ gTypeArgs
  let vs = map EVar . take (nargs ftype) $ freshVarsAZ [] -- TODO: exclude existing arguments
      ys = zipWith3 makeVar vs (typeArgsC ftype) gTypeArgs
  -- unsafe, but should not fail for well-typed input
      appType = fromJust . last . typeArgsC $ ftype
      appMeta = m {metaGType = metaGType m >>= (last . typeArgsG)}
      lamMeta = m {metaGType = Just lamGType}
      lamCType = ftype

  return $ SAnno (One (LamS vs (SAnno (One (AppS f' (xs' ++ ys), appType)) appMeta), lamCType)) lamMeta
  where
    makeGType :: [Maybe GType] -> MorlocMonad GType
    makeGType ts = fmap GType . makeType . map unGType $ (map fromJust ts)
    -- make an sanno variable from variable name and type info
    makeVar :: EVar -> Maybe CType -> Maybe GType -> SAnno GMeta One CType
    makeVar _ Nothing _ = error "Yeah, so this can happen"
    makeVar v (Just c) g = SAnno (One (VarS v, c))
      ( m { metaGType = g
          , metaName = Nothing
          , metaProperties = Set.empty
          , metaConstraints = Set.empty
          }
      )
-- apply the pattern above down the AST
rewritePartials (SAnno (One (AppS f xs, t)) m) = do
  xs' <- mapM rewritePartials xs
  f' <- rewritePartials f
  return $ SAnno (One (AppS f' xs', t)) m
rewritePartials (SAnno (One (LamS vs x, t)) m) = do
  x' <- rewritePartials x
  return $ SAnno (One (LamS vs x', t)) m
rewritePartials (SAnno (One (ListS xs, t)) m) = do
  xs' <- mapM rewritePartials xs
  return $ SAnno (One (ListS xs', t)) m
rewritePartials (SAnno (One (TupleS xs, t)) m) = do
  xs' <- mapM rewritePartials xs
  return $ SAnno (One (TupleS xs', t)) m
rewritePartials (SAnno (One (RecS entries, t)) m) = do
  let keys = map fst entries
  vals <- mapM rewritePartials (map snd entries)
  return $ SAnno (One (RecS (zip keys vals), t)) m
rewritePartials x = return x

writeManyAST :: SAnno GMeta Many [CType] -> MDoc
writeManyAST (SAnno (Many xs) g) =
     pretty (metaId g)
  <> maybe "" (\n -> " " <> pretty n) (metaName g)
  <+> "::" <+> maybe "_" prettyType (metaGType g)
  <> line <> indent 5 (vsep (map writeSome xs))
  where
    writeSome :: (SExpr GMeta Many [CType], [CType]) -> MDoc
    writeSome (s, ts)
      =  "_ ::"
      <+> encloseSep "{" "}" ";" (map prettyType ts)
      <> line <> writeExpr s

    writeExpr :: SExpr GMeta Many [CType] -> MDoc
    writeExpr (ListS xs) = list (map writeManyAST xs)
    writeExpr (TupleS xs) = list (map writeManyAST xs)
    writeExpr (RecS entries) = encloseSep "{" "}" "," $
      map (\(k,v) -> pretty k <+> "=" <+> writeManyAST v) entries
    writeExpr (LamS vs x)
      = "LamS"
      <+> list (map pretty vs)
      <> line <> indent 2 (writeManyAST x)
    writeExpr (AppS f xs) = "AppS" <+> indent 2 (vsep (writeManyAST f : map writeManyAST xs))
    writeExpr x = descSExpr x

writeAST
  :: (a -> CType) -> Maybe (a -> MDoc) -> SAnno GMeta One a -> MDoc
writeAST getType extra s = hang 2 . vsep $ ["AST:", describe s]
  where
    addExtra x = case extra of
      (Just f) -> " " <> f x
      Nothing -> ""

    describe (SAnno (One (x@(ListS xs), _)) _) = descSExpr x
    describe (SAnno (One (x@(TupleS xs), _)) _) = descSExpr x
    describe (SAnno (One (x@(RecS xs), _)) _) = descSExpr x
    describe (SAnno (One (x@(AppS f xs), c)) g) =
      hang 2 . vsep $
        [ pretty (metaId g) <+> descSExpr x <+> parens (prettyType (getType c)) <> addExtra c
        , describe f
        ] ++ map describe xs
    describe (SAnno (One (f@(LamS _ x), c)) g) = do 
      hang 2 . vsep $
        [ pretty (metaId g)
            <+> name (getType c) g
            <+> descSExpr f
            <+> parens (prettyType (getType c))
            <> addExtra c
        , describe x
        ] 
    describe (SAnno (One (x, c)) g) =
          pretty (metaId g)
      <+> descSExpr x
      <+> parens (prettyType (getType c))
      <>  addExtra c

    name :: CType -> GMeta -> MDoc
    name (viaShow . langOf' -> lang) g =
      maybe
        ("_" <+> lang <+> "::")
        (\x -> pretty x <+> lang <+> "::")
        (metaName g)


-- | Add arguments that are required for each term. Unneeded arguments are
-- removed at each step.
parameterize
  :: SAnno GMeta One CType
  -> MorlocMonad (SAnno GMeta One (CType, [Argument]))
parameterize (SAnno (One (LamS vs x, t)) m) = do
  let args0 = zipWith makeArgument vs (typeArgsC t)
  x' <- parameterize' args0 x
  return $ SAnno (One (LamS vs x', (t, args0))) m
parameterize (SAnno (One (CallS src, t)) m) = do
  ts <- case sequence (typeArgsC t) of
    (Just ts') -> return (init ts')
    Nothing -> MM.throwError . TypeError . render $
      "Unexpected type in parameterize CallS:" <+> prettyType t
  let vs = map EVar (freshVarsAZ [])
      args0 = zipWith makeArgument vs (map Just ts)
  return $ SAnno (One (CallS src, (t, args0))) m
parameterize x = parameterize' [] x

-- TODO: the arguments coupled to every term should be the arguments USED
-- (not inherited) by the term. I need to ensure the argument threading
-- leads to correct passing of packed/unpacked arguments. AppS should
-- "know" that it needs to pack functions that are passed to a foreign
-- call, for instance.
parameterize'
  :: [Argument] -- arguments in parental scope (child needn't retain them)
  -> SAnno GMeta One CType
  -> MorlocMonad (SAnno GMeta One (CType, [Argument]))
-- primitives, no arguments are required for a primitive, so empty lists
parameterize' _ (SAnno (One (UniS, c)) m) = return $ SAnno (One (UniS, (c, []))) m
parameterize' _ (SAnno (One (NumS x, c)) m) = return $ SAnno (One (NumS x, (c, []))) m
parameterize' _ (SAnno (One (LogS x, c)) m) = return $ SAnno (One (LogS x, (c, []))) m
parameterize' _ (SAnno (One (StrS x, c)) m) = return $ SAnno (One (StrS x, (c, []))) m
-- VarS EVar
parameterize' args (SAnno (One (VarS v, c)) m) = do
  let args' = filter (\r -> argName r == v) args
  return $ SAnno (One (VarS v, (c, args'))) m
-- CallS Source
parameterize' args (SAnno (One (CallS src, c)) m) = do
  return $ SAnno (One (CallS src, (c, []))) m
-- containers
parameterize' args (SAnno (One (ListS xs, c)) m) = do
  xs' <- mapM (parameterize' args) xs
  let args' = unique . concat . map sannoSnd $ xs'
  return $ SAnno (One (ListS xs', (c, args'))) m
parameterize' args (SAnno (One (TupleS xs, c)) m) = do
  xs' <- mapM (parameterize' args) xs
  let args' = unique . concat . map sannoSnd $ xs'
  return $ SAnno (One (TupleS xs', (c, args'))) m
parameterize' args (SAnno (One (RecS entries, c)) m) = do
  vs' <- mapM (parameterize' args) (map snd entries)
  let args' = unique . concat . map sannoSnd $ vs'
  return $ SAnno (One (RecS (zip (map fst entries) vs'), (c, args'))) m
parameterize' _ (SAnno (One (LamS vs x, c)) m) = do
  let args0 = map unpackArgument $ zipWith makeArgument vs (typeArgsC c)
  x' <- parameterize' args0 x
  return $ SAnno (One (LamS vs x', (c, []))) m 
parameterize' args (SAnno (One (AppS x xs, c)) m) = do
  x' <- parameterize' args x
  xs' <- mapM (parameterize' args) xs
  let args' = sannoSnd x' ++ (unique . concat . map sannoSnd) xs'
  return $ SAnno (One (AppS x' xs', (c, args'))) m
parameterize' args (SAnno (One (ForeignS i lang vs, c)) m) =
  case sequence $ map listToMaybe [[r | r <- args, argName r == v] | v <- vs] of
    Nothing -> MM.throwError . GeneratorError $ "Bad argument sent to ForeignS"
    Just args' -> return $ SAnno (One (ForeignS i lang vs, (c, args'))) m

-- | This function handles the mechanics of segmentation, not the choice of
-- languages or the let-optimizations that ultimately determine which
segment
  :: SAnno GMeta One (CType, [Argument])
  -> MorlocMonad [SAnno GMeta One (CType, [Argument])]
segment x@(SAnno (One (_, c)) _) = do
  -- say $ " ---- entering segment"
  (x', xs) <- segment' (fst c) x
  -- say $ line <> indent 2 (vsep (map writeAST' (x' : xs)))
  return (x' : xs)
  where
    writeAST' = writeAST fst (Just (list . map prettyArgument . snd))

    segment' 
      :: CType
      -> SAnno GMeta One (CType, [Argument])
      -> MorlocMonad
         ( SAnno GMeta One (CType, [Argument])
         , [SAnno GMeta One (CType, [Argument])])
    segment' _ x@(SAnno (One (UniS  , _)) _) = return (x, [])
    segment' _ x@(SAnno (One (NumS _, _)) _) = return (x, [])
    segment' _ x@(SAnno (One (LogS _, _)) _) = return (x, [])
    segment' _ x@(SAnno (One (StrS _, _)) _) = return (x, [])
    segment' _ x@(SAnno (One (VarS _, _)) _) = return (x, [])
    segment' _ (SAnno (One (ListS xs, c)) m) = do
      t <- listType (fst c)
      (xs', rs) <- mapM (segment' t) xs |>> unzip
      return (SAnno (One (ListS xs', c)) m, concat rs)
      where
        listType :: CType -> MorlocMonad CType
        listType (CType (ArrT _ [t])) = return (CType t)
        recTypes _ = MM.throwError . TypeError $ "Expected exactly one parameter for List type"
    segment' _ (SAnno (One (TupleS xs, c)) m) = do
      ts <- tupleTypes (fst c)
      (xs', rs) <- zipWithM segment' ts xs |>> unzip
      return (SAnno (One (TupleS xs', c)) m, concat rs)
      where
        tupleTypes :: CType -> MorlocMonad [CType]
        tupleTypes (CType (ArrT _ ts)) = return (map CType ts)
    segment' _ (SAnno (One (RecS xs, c)) m) = do
      ts <- recTypes (fst c)
      (vals, rs) <- zipWithM segment' ts (map snd xs) |>> unzip
      return (SAnno (One (RecS (zip (map fst xs) vals), c)) m, concat rs)
      where
        recTypes :: CType -> MorlocMonad [CType]
        recTypes (CType (NamT _ entries)) = return (map (CType . snd) entries)
        recTypes _ = MM.throwError . TypeError $ "Expected Record type"
    segment' t0 (SAnno (One (LamS vs x, c1)) m)
      | langOf' t0 == langOf' (fst c1) = do
          (x', rs) <- segment' (fromJust . last . typeArgsC . fst $ c1) x
          return (SAnno (One (LamS vs x', c1)) m, rs)
      | otherwise = MM.throwError . NotImplemented $
        "Foreign lambda's are not currently supported"
    segment' t0 (SAnno (One (AppS x@(SAnno (One (CallS src, c2)) m2) xs, c1)) m) = do

      (xs', xsrss) <- zipWithM segment' (typeArgsC' (fst c2)) xs |>> unzip
      case langOf' t0 == langOf' (fst c2) of
        True -> return (SAnno (One (AppS x xs', c1)) m, concat xsrss)
        False -> do

          let lamArgs = typeArgsC (fst c2)
              lamType = fst c2
          -- argument names shared between segments
              vs' = map argName (snd c1)

          let foreignArgs = zipWith makeArgument vs' lamArgs

          -- FIXME: soooooo ugly ...
          let (SAnno (One (AppS x' xs'', c1'@(_, lamRs'))) _) = mapC (reparameterize foreignArgs) (SAnno (One (AppS x xs', c1)) m)

          -- foreign function argument type
          let foreignCMeta = (t0, snd c1)
              appCMeta = (fst c1, foreignArgs)
          -- let meta for each produced expression
          -- all three should have the same metaId
              foreignMeta = m
              lamMeta = m2 {metaId = metaId m} -- FIXME - need to adjust the general type
              appMeta = m2 {metaId = metaId m} -- FIXME - need to adjust the general type
          -- final three
          -- the terminal manifold in L1 in this segment, same type as the AppS
              foreignCall = SAnno (One (ForeignS (metaId m) (langOf' (fst c2)) vs', foreignCMeta)) foreignMeta
              foreignApp = SAnno (One (AppS x' xs'', c1')) appMeta
              foreignLam = SAnno (One (LamS vs' foreignApp, (lamType, lamRs'))) lamMeta
          return (foreignCall , foreignLam : concat xsrss)
    segment' _ x@(SAnno (One (CallS _, _)) _) = return (x, [])

-- Now that the AST is segmented by language, we can resolve passed-through
-- arguments where possible.
reparameterize
  :: [Argument]
  -> (CType, [Argument])
  -> (CType, [Argument])
reparameterize args0 (t, args1) = (t, map f args1)
  where
    f :: Argument -> Argument
    f r@(PackedArgument _ _) = r
    f r@(UnpackedArgument _ _) = r
    f r@(PassThroughArgument v) =
      case [r' | r' <- args0, argName r' == v] of
        (r':_) -> r'
        _ -> r

makeArgument :: EVar -> Maybe CType -> Argument 
makeArgument v (Just t) = PackedArgument v t
makeArgument v Nothing = PassThroughArgument v


-- Sort manifolds into pools. Within pools, group manifolds into call sets.
pool
  :: [SAnno GMeta One (CType, [Argument])]
  -> MorlocMonad [(Lang, [SAnno GMeta One (CType, [Argument])])]
pool = return . groupSort . map (\s@(SAnno (One (_, (t, _))) _) -> (langOf' t, s))


encode
  :: [Source]
  -> (Lang, [SAnno GMeta One (CType, [Argument])])
  -> MorlocMonad Script
encode srcs (lang, xs) = do
  state <- MM.get

  let srcs' = unique [s | s <- srcs, srcLang s == lang]

  -- translate each node in the AST to code
  code <- mapM codify xs >>= translate lang srcs'

  return $ Script
    { scriptBase = "pool"
    , scriptLang = lang
    , scriptCode = Code . render $ code
    , scriptCompilerFlags =
        filter (/= "") . map packageGccFlags $ statePackageMeta state
    , scriptInclude = unique . map MS.takeDirectory $
        (unique . catMaybes) (map srcPath srcs')
    }

codify
  :: SAnno GMeta One (CType, [Argument])
  -> MorlocMonad [Manifold]
codify x = fmap fst $ codify' True x

-- | Make general manifolds. The goal is to do as much work as possible before
-- invoking language-specific behaviour. Eventually manifold effects and
-- control will be added here (caches, assertions, logging, visualization,
-- etc). Following steps will extract assignments, handle serialization and
-- schemas, and finally translate to executable code.
codify'
  :: Bool
  -> SAnno GMeta One (CType, [Argument])
  -> MorlocMonad ([Manifold], ExprM)
-- primitives
codify' _ (SAnno (One (UniS,   (c, _))) _) = return ([], NullM c)
codify' _ (SAnno (One (NumS x, (c, _))) _) = return ([], (NumM c x))
codify' _ (SAnno (One (LogS x, (c, _))) _) = return ([], (LogM c x))
codify' _ (SAnno (One (StrS x, (c, _))) _) = return ([], (StrM c x))
-- list
codify' isTop s@(SAnno (One (ListS xs, (c, args))) m) = do
  (mss, xs') <- fmap unzip (mapM (codify' False) xs)
  let x = ListM c xs'
  codifyContainer isTop mss x s 
-- tuple
codify' isTop s@(SAnno (One (TupleS xs, (c, args))) m) = do
  (mss, xs') <- fmap unzip (mapM (codify' False) xs)
  let x = TupleM c xs'
  codifyContainer isTop mss x s 
-- record
codify' isTop s@(SAnno (One (RecS es, (c, args))) m) = do
  (mss, xs') <- fmap unzip (mapM (codify' False) (map snd es))
  let x = RecordM c (zip (map fst es) xs')
  codifyContainer isTop mss x s 
-- var
codify' _ (SAnno (One (VarS v, (c, _))) _) = return ([], VarM c v)
-- lambda
codify' _ (SAnno (One (LamS _ x, (c, _))) _) = codify' False x
-- foreign call
codify' _ (SAnno (One (ForeignS mid lang vs, (c, args))) m) = do
  return ([], ForeignCallM c mid lang vs)
-- domestic call
codify' False (SAnno (One (CallS src, (c, args))) m) =
  return ([], VarM c (EVar (unName (srcName src))))
codify' True (SAnno (One (CallS src, (c, args))) m) = do
  let x = VarM c (EVar (unName (srcName src)))
      manifold = Manifold (UnpackedReturn (metaId m) c) args [ReturnM x]
  return ([manifold], x)
-- applcation
codify' _ (SAnno (One (AppS f xs, (c, args))) m) = do
  (ms', f') <- codify' False f
  (mss', xs') <- fmap unzip $ mapM (codify' False) xs
  let mid = metaId m
      ms = ms' ++ concat mss'
  case f' of
    x@(ForeignCallM _ _ _ _) ->
      return
        (Manifold (PackedReturn mid c) args [ReturnM x] : ms
        , x
        )
    x@(VarM _ _) ->
      return
        ( Manifold (UnpackedReturn mid c) args [ReturnM (SrcCallM c x xs')] : ms
        , ManCallM c mid (map (\r -> VarM (fromJust $ argType r) (argName r)) args)
        )

codifyContainer
  :: Bool
  -> [[Manifold]]
  -> ExprM
  -> SAnno GMeta One (CType, [Argument])
  -> MorlocMonad ([Manifold], ExprM)
codifyContainer isTop mss x (SAnno (One (_, (c, args))) m) =
  if isTop
    then return (Manifold (UnpackedReturn (metaId m) c) args [x] : concat mss, x)
    else return (concat mss, x)

translate :: Lang -> [Source] -> [[Manifold]] -> MorlocMonad MDoc
translate lang srcs mss = do
  let callTrees = [CallTree m ms | (m:ms) <- mss]
  case lang of
    CppLang -> Cpp.translate srcs callTrees
    RLang -> R.translate srcs callTrees
    Python3Lang -> Python3.translate srcs callTrees
    x -> MM.throwError . OtherError . render
      $ "Language '" <> viaShow x <> "' has no translator" 


-------- Utility and lookup functions ----------------------------------------

say :: Doc ann -> MorlocMonad ()
say d = liftIO . putDoc $ " : " <> d <> "\n"

unrollLambda :: Expr -> ([EVar], Expr)
unrollLambda (LamE v e2) = case unrollLambda e2 of
  (vs, e) -> (v:vs, e)
unrollLambda (AnnE (LamE v e2) _) = case unrollLambda e2 of
  (vs, e) -> (v:vs, e)
unrollLambda e = ([], e)

getGType :: [Type] -> MorlocMonad (Maybe GType)
getGType ts = case [GType t | t <- ts, langOf' t == MorlocLang] of
  [] -> return Nothing
  [x] -> return $ Just x
  xs -> MM.throwError . GeneratorError $
    "Expected 0 or 1 general types, found " <> MT.show' (length xs)

getCTypes :: [Type] -> [CType]
getCTypes ts = [CType t | t <- ts, isJust (langOf t)]

-- resolves a function into a list of types, for example:
-- ((Num->String)->[Num]->[String]) would resolve to the list
-- [(Num->String),[Num],[String]]. Any unsolved variables (i.e., that are still
-- universally qualified) will be stored as Nothing. Such variables will always
-- be passthrough arguments that have unknown type in the current language, but
-- will be passed on to one where they are defined.
typeArgsC :: CType -> [Maybe CType]
typeArgsC t = map (fmap ctype) (typeArgs [] (unCType t))

typeArgsG :: GType -> [Maybe GType]
typeArgsG t = map (fmap GType) (typeArgs [] (unGType t))

typeArgs :: [TVar] -> Type -> [Maybe Type]
typeArgs unsolved (FunT t1@(VarT v) t2)
  | elem v unsolved = Nothing : typeArgs unsolved t2
  | otherwise = Just t1 : typeArgs unsolved t2
typeArgs unsolved (FunT t1 t2) = Just t1 : typeArgs unsolved t2
typeArgs unsolved (Forall v t) = typeArgs (v:unsolved) t
typeArgs unsolved t@(VarT v)
  | elem v unsolved = [Nothing]
  | otherwise = [Just t]
typeArgs unsolved t = [Just t]

-- The typeArgs*' functions are like the typeArgs* functions except they
-- replace Nothing with `forall a . a`. Basically, Anything instead of Nothing.
typeArgsC' :: CType -> [CType]
typeArgsC' t = map ctype (typeArgs' [] (unCType t))

typeArgsG' :: GType -> [GType]
typeArgsG' t = map GType (typeArgs' [] (unGType t))

typeArgs' :: [TVar] -> Type -> [Type]
typeArgs' unsolved (FunT t1@(VarT v) t2)
  | elem v unsolved = Forall v t1 : typeArgs' unsolved t2
  | otherwise = t1 : typeArgs' unsolved t2
typeArgs' unsolved (FunT t1 t2) = t1 : typeArgs' unsolved t2
typeArgs' unsolved (Forall v t) = typeArgs' (v:unsolved) t
typeArgs' unsolved t@(VarT v)
  | elem v unsolved = [Forall v t]
  | otherwise = [t]
typeArgs' _ t = [t]

makeManifoldName :: GMeta -> EVar
makeManifoldName m = EVar $ "m" <> MT.show' (metaId m)

makeArgumentName :: Int -> MDoc
makeArgumentName i = "x" <> pretty i

getTermModule :: TermOrigin -> Module
getTermModule (Sourced m _) = m
getTermModule (Declared m _ _) = m

getTermEVar :: TermOrigin -> EVar
getTermEVar (Sourced _ src) = srcAlias src
getTermEVar (Declared _ v _) = v

getTermTypeSet :: TermOrigin -> MorlocMonad TypeSet
getTermTypeSet t =
  case Map.lookup (getTermEVar t) (moduleTypeMap (getTermModule t)) of
    (Just ts) -> return ts
    Nothing -> MM.throwError . GeneratorError $ "Expected the term to have a typeset"

unpackSAnno :: (SExpr g One c -> g -> c -> a) -> SAnno g One c -> [a]
unpackSAnno f (SAnno (One (e@(ListS xs),     c)) g) = f e g c : conmap (unpackSAnno f) xs
unpackSAnno f (SAnno (One (e@(TupleS xs),    c)) g) = f e g c : conmap (unpackSAnno f) xs
unpackSAnno f (SAnno (One (e@(RecS entries), c)) g) = f e g c : conmap (unpackSAnno f) (map snd entries)
unpackSAnno f (SAnno (One (e@(LamS _ x),     c)) g) = f e g c : unpackSAnno f x
unpackSAnno f (SAnno (One (e@(AppS x xs),    c)) g) = f e g c : conmap (unpackSAnno f) (x:xs)
unpackSAnno f (SAnno (One (e, c)) g)                = [f e g c]

sannoWithC :: (c -> a) -> SAnno g One c -> a
sannoWithC f (SAnno (One (_, c)) _) = f c

mapC :: (c -> a) -> SAnno g One c -> SAnno g One a
mapC f (SAnno (One (ListS xs, c)) g) =
  SAnno (One (ListS (map (mapC f) xs), f c)) g
mapC f (SAnno (One (TupleS xs, c)) g) =
  SAnno (One (TupleS (map (mapC f) xs), f c)) g
mapC f (SAnno (One (RecS entries, c)) g) =
  SAnno (One (RecS (map (\(k, v) -> (k, mapC f v)) entries), f c)) g
mapC f (SAnno (One (LamS vs x, c)) g) =
  SAnno (One (LamS vs (mapC f x), f c)) g
mapC f (SAnno (One (AppS x xs, c)) g) =
  SAnno (One (AppS (mapC f x) (map (mapC f) xs), f c)) g
mapC f (SAnno (One (VarS x, c)) g) = SAnno (One (VarS x, f c)) g
mapC f (SAnno (One (CallS src, c)) g) = SAnno (One (CallS src, f c)) g
mapC f (SAnno (One (UniS, c)) g) = SAnno (One (UniS, f c)) g
mapC f (SAnno (One (NumS x, c)) g) = SAnno (One (NumS x, f c)) g
mapC f (SAnno (One (LogS x, c)) g) = SAnno (One (LogS x, f c)) g
mapC f (SAnno (One (StrS x, c)) g) = SAnno (One (StrS x, f c)) g
mapC f (SAnno (One (ForeignS i lang vs, c)) g) = SAnno (One (ForeignS i lang vs, f c)) g

descSExpr :: SExpr g f c -> MDoc
descSExpr (UniS) = "UniS"
descSExpr (VarS v) = "VarS" <+> pretty v
descSExpr (CallS src)
  =   "CallS"
  <+> pretty (srcAlias src) <+> "<" <> viaShow (srcLang src) <> ">"
descSExpr (ListS _) = "ListS"
descSExpr (TupleS _) = "TupleS"
descSExpr (LamS vs _) = "LamS" <+> hsep (map pretty vs)
descSExpr (AppS _ _) = "AppS"
descSExpr (NumS _) = "NumS"
descSExpr (LogS _) = "LogS"
descSExpr (StrS _) = "StrS"
descSExpr (RecS _) = "RecS"
descSExpr (ForeignS i lang vs) =
  parens (hsep ("ForeignS" : map pretty vs)) <+> pretty i <+> viaShow lang

partialApply :: Type -> MorlocMonad Type
partialApply (FunT _ t) = return t
partialApply (Forall v t) = do
  t' <- partialApply t
  return $ if varIsUsed v t' then Forall v t' else t'
  where
    varIsUsed :: TVar -> Type -> Bool 
    varIsUsed v (VarT v') = v == v'
    varIsUsed v (ExistT v' ts ds)
      =  v == v'
      || any (varIsUsed v) ts
      || any (varIsUsed v) (map unDefaultType ds)
    varIsUsed v (Forall v' t)
      | v == v' = False
      | otherwise = varIsUsed v t
    varIsUsed v (FunT t1 t2) = varIsUsed v t1 || varIsUsed v t2
    varIsUsed v (ArrT v' ts) = any (varIsUsed v) ts
    varIsUsed v (NamT v' entries) = any (varIsUsed v) (map snd entries)
partialApply _ = MM.throwError . GeneratorError $
  "Cannot partially apply a non-function type"

partialApplyN :: Int -> Type -> MorlocMonad Type
partialApplyN i t
  | i < 0 = MM.throwError . GeneratorError $
    "Do you really want to apply a negative number of arguments?"
  | i == 0 = return t
  | i > 0 = do
    appliedType <- partialApply t
    partialApplyN (i-1) appliedType

pack :: Argument -> Argument
pack (UnpackedArgument v t) = PackedArgument v t
pack x = x

unpack :: Argument -> Argument
unpack (PackedArgument v t) = UnpackedArgument v t
unpack x = x

sannoSnd :: SAnno g One (a, b) -> b
sannoSnd (SAnno (One (_, (_, x))) _) = x

-- generate infinite list of fresh variables of form ['a','b',...,'z','aa','ab',...,'zz',...]
freshVarsAZ
  :: [MT.Text] -- variables to exclude
  -> [MT.Text]
freshVarsAZ exclude =
  filter
    (\x -> not (elem x exclude))
    ([1 ..] >>= flip replicateM ['a' .. 'z'] |>> MT.pack)

-- turn type list into a function
makeType :: [Type] -> MorlocMonad Type
makeType [] = MM.throwError . TypeError $ "empty type"
makeType [t] = return t
makeType (t:ts) = FunT <$> pure t <*> makeType ts

{- | Find exported expressions.

Terms may be declared or sourced in the current module or they may be imported
from a different module. If they are imported, ascend through modules to the
original declaration, returning the module where they are defined.

For each input term (EVar) a list is returned. Each element in the list
describes a specific implementation of the term. These implementations may have
different topologies and languages. A given language may have more than one
implementation. However, all implementations share the same general type.

Each element in the return list is a tuple of two values. The module where the
term is exported and the source/declaration information needed to uniquely
specify it (within an Either monad). If the term is sourced, then a (Left
Source) data constructor holds the required source information. If the term is
declared, a (EVar, Expr) tuple stores the left and right sides of a declaration
(the same information that is stored in the Declaration data constructor of
Expr).
-}
findTerm
  :: Bool -- ^ should non-exported terms be included?
  -> Map.Map MVar Module
  -> Module -- ^ a module where EVar is used
  -> EVar -- ^ the variable name in the top level module
  -> [TermOrigin]
findTerm includeInternal ms m v
  | includeInternal || Set.member v (moduleExports m)
      = evarDeclared
      ++ evarSourced
      ++ evarImported
  | otherwise = []
  where
    evarDeclared :: [TermOrigin]
    evarDeclared = case Map.lookup v (moduleDeclarationMap m) of
      -- If a term is defined as being equal to another term, find this other term.
      (Just (VarE v')) -> if v /= v'
        then findTerm False ms m v'
        else error "found term of type `x = x`, the typechecker should have died on this ..."
      (Just e) -> [Declared m v e]
      _ -> []

    evarSourced :: [TermOrigin]
    evarSourced = map (\(_, src) -> Sourced m src)
                . Map.toList
                . Map.filterWithKey (\(v',_) _ -> v' == v)
                $ moduleSourceMap m

    evarImported :: [TermOrigin]
    evarImported =
      concat [findTerm False ms m' v | m' <- mapMaybe (flip Map.lookup $ ms) (listMVars m)]

    typeEVar :: EVar -> Expr
    typeEVar name = case Map.lookup name (moduleTypeMap m) of
      (Just (TypeSet t ts)) -> AnnE (VarE name) (map etype (maybe ts (\t' -> t':ts) t))
      Nothing -> error $ "Variable '" <> MT.unpack (unEVar name) <> "' is not defined"

    listMVars :: Module -> [MVar]
    listMVars m = Map.elems $ Map.filterWithKey (\v' _ -> v' == v) (moduleImportMap m)
