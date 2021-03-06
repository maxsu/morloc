{-|
Module      : Morloc.Data.DAG
Description : Functions for working with directed acyclic graphs
Copyright   : (c) Zebulun Arendsee, 2020
License     : GPL-3
Maintainer  : zbwrnz@gmail.com
Stability   : experimental
-}

module Morloc.Data.DAG
  ( edgelist
  , insertEdge
  , edges
  , nodes
  , lookupNode
  , lookupEdge
  , lookupEdgeTriple
  , local
  , roots
  , leafs
  , findCycle
  , mapNode
  , mapNodeM
  , mapNodeWithKey
  , mapNodeWithKeyM
  , mapEdge
  , mapEdgeWithNode
  , mapNodeWithEdge
  , mapEdgeWithNodeM
  , lookupAliasedTerm
  , lookupAliasedTermM
  , synthesizeDAG
  ) where

import Morloc.Namespace
import qualified Morloc.Monad as MM
import qualified Data.Map as Map 
import qualified Data.Set as Set 

edgelist :: DAG k e n -> [(k,k)]
edgelist d = concat [[(k,j) | (j,_) <- xs] | (k, (_, xs)) <- Map.toList d ]

insertEdge :: Ord k => k -> k -> e -> DAG k e n -> DAG k e n
insertEdge k1 k2 e d = Map.alter f k1 d
  where  
    -- f :: Maybe [(k, e)] -> Maybe [(k, e)]
    f Nothing = error "Cannot add edge to non-existant node"
    f (Just (n,xs)) = Just $ (n,(k2,e):xs)

-- | Get all edges
edges :: DAG k e n -> [e]
edges = map snd . concat . map snd . Map.elems

-- | Get all nodes
nodes :: DAG k e n -> [n]
nodes = map fst . Map.elems

lookupNode :: Ord k => k -> DAG k e n -> Maybe n
lookupNode k d = case Map.lookup k d of
  (Just (n,_)) -> Just n
  Nothing -> Nothing

lookupEdge :: (Ord k) => k -> k -> DAG k e n -> Maybe e
lookupEdge k1 k2 d = case Map.lookup k1 d of
  (Just (_,xs)) -> lookup k2 xs
  Nothing -> Nothing

lookupEdgeTriple :: (Ord k) => k -> k -> DAG k e n -> Maybe (n, e, n)
lookupEdgeTriple k1 k2 d = do
  (n1, xs) <- Map.lookup k1 d
  e <- lookup k2 xs
  (n2, _) <- Map.lookup k2 d
  return (n1, e, n2)

local :: Ord k => k -> DAG k e n -> Maybe (n, [(k, e, n)])
local k d = do
  (n1, xs) <- Map.lookup k d
  ns <- mapM (flip lookupNode $ d) (map fst xs)
  return $ (n1, [(k',e,n2) | (n2, (k', e)) <- zip ns xs])

-- | Get all roots
roots :: Ord k => DAG k e n -> [k]
roots d = Set.toList $ Set.difference parents children
  where
    g = edgelist d
    parents = Map.keysSet d
    children = Set.fromList (map snd g)

-- | Get all leaves that have no children
leafs :: DAG k e n -> [k]
leafs d = [k | (k, (_, [])) <- Map.toList d]

-- | Searches a DAG for a cycle, stops on the first observed cycle and returns
-- the path.
findCycle :: Ord k => DAG k e n -> Maybe [k]
findCycle d = case mapMaybe (findCycle' []) (roots d) of 
  [] -> Nothing
  (x:_) -> Just x
  where
    -- findCycle' :: [k] -> k -> Maybe [k]
    findCycle' seen k
      | elem k seen = Just seen
      | otherwise = case Map.lookup k d of
          Nothing -> Nothing -- we have reached a leaf
          (Just (_,xs)) -> case mapMaybe (findCycle' (k:seen)) (map fst xs) of
            [] -> Nothing
            (x:_) -> Just x

-- Map function over nodes independent of the edge data
mapNode :: (n1 -> n2) -> DAG k e n1 -> DAG k e n2
mapNode f d = Map.map (\(n, xs) -> (f n, xs)) d

mapNodeWithKey :: (k -> n1 -> n2) -> DAG k e n1 -> DAG k e n2
mapNodeWithKey f d = Map.mapWithKey (\k (n, xs) -> (f k n, xs)) d

-- Map function over nodes independent of the edge data
mapNodeM :: Ord k => (n1 -> MorlocMonad n2) -> DAG k e n1 -> MorlocMonad (DAG k e n2)
mapNodeM f d
  = mapM (\(k,(n,xs)) -> f n >>= (\n' -> return (k, (n',xs)))) (Map.toList d)
  |>> Map.fromList

-- Map function over nodes independent of the edge data
mapNodeWithKeyM :: Ord k => (k -> n1 -> MorlocMonad n2) -> DAG k e n1 -> MorlocMonad (DAG k e n2)
mapNodeWithKeyM f d
  = mapM (\(k,(n,xs)) -> f k n >>= (\n' -> return (k, (n',xs)))) (Map.toList d)
  |>> Map.fromList

-- Map function over edges independent of the node data
mapEdge :: (e1 -> e2) -> DAG k e1 n -> DAG k e2 n
mapEdge f = Map.map (\(n, xs) -> (n, [(k, f e) | (k,e) <- xs]))

-- | map over edges given the nodes the edge connects
mapEdgeWithNode
  :: Ord k
  => (n -> e1 -> n -> e2)
  -> DAG k e1 n -> DAG k e2 n
mapEdgeWithNode f d = Map.mapWithKey runit d where
  runit k _ = case local k d of
    (Just (n1, xs)) -> (n1, [(k2, f n1 e n2) | (k2, e, n2) <- xs])
    Nothing -> error "Bad DAG"

-- | Map node data given edges and child data
mapNodeWithEdge
  :: Ord k
  => (n1 -> [(k, e, n1)] -> n2)
  -> DAG k e n1 -> DAG k e n2
mapNodeWithEdge f d = Map.mapWithKey fkey d where
  fkey k1 (_, xs0) = case local k1 d of
    (Just (n1, xs1)) -> (f n1 xs1, xs0)
    Nothing -> error "Bad DAG"

-- | map over edges given the nodes the edge connects
mapEdgeWithNodeM
  :: Ord k
  => (n -> e1 -> n -> MorlocMonad e2)
  -> DAG k e1 n -> MorlocMonad (DAG k e2 n)
mapEdgeWithNodeM f d = mapM runit (Map.toList d) |>> Map.fromList
  where
    runit (k1, _) = case local k1 d of 
      (Just (n1, xs)) -> do
        e2s <- mapM (\(_, e, n2) -> f n1 e n2) xs
        return (k1, (n1, zip (map (\(x,_,_)->x) xs) e2s))
      Nothing -> MM.throwError . CallTheMonkeys $ "Incomplete DAG, missing object"

-- | Map a monadic function over a DAG yielding a new DAG with the same
-- topology but a new node values. If the DAG contains cycles, Nothing is
-- returned.
synthesizeDAG
  :: (Ord k, Monad m)
  => (k -> n1 -> [(k, e, n2)] -> m n2)
  -> DAG k e n1
  -> m (Maybe (DAG k e n2))
synthesizeDAG f d0 = synthesizeDAG' (Just Map.empty) where
  -- iteratively synthesize all nodes that have met dependencies
  synthesizeDAG' Nothing = return Nothing
  synthesizeDAG' (Just dn)
    -- stop, we have completed the mapping. Jubilation.
    | Map.size d0 == Map.size dn = return (Just dn) 
    | otherwise = do
        -- traverse the original making any nodes that now have met dependencies
        dn' <- foldlM addIfPossible dn (Map.toList d0)
        if Map.size dn' == Map.size dn
          -- if map size hasn't changed, then nothing was added and we are stuck
          then return Nothing
          -- otherwise move on to the next iteration
          else synthesizeDAG' (Just dn')

  -- add leaves
  addIfPossible dn (k1, (n1, []))
    | Map.member k1 dn = return dn
    | otherwise = do
        n2 <- f k1 n1 []
        return $ Map.insert k1 (n2, []) dn
  -- add nodes where all children have been processed
  addIfPossible dn (k1, (n1, xs))
    | Map.member k1 dn = return dn
    | otherwise = case mapM (\k -> Map.lookup k dn) (map fst xs) of
        Nothing -> return dn
        (Just children) -> do
          let augmented = [(k,e,n2) | ((k, e), (n2, _)) <- zip xs children]
          n2 <- f k1 n1 augmented
          return $ Map.insert k1 (n2, xs) dn


lookupAliasedTerm
  :: (Ord k, Eq v)
  => v
  -- ^ look up this term
  -> k
  -- ^ starting from this node
  -> (n -> a)
  -- ^ extract the desired data with this function
  -> DAG k [(v,v)] n
  -- ^ original DAG where edges are "import as" statements
  -> DAG k None (v,a)
  -- ^ The final DAG with no edge attribute and the 
lookupAliasedTerm v0 k0 f d0 = fromJust $ lookupAliasedTermM v0 k0 (Just . f) d0

lookupAliasedTermM
  :: (Monad m, Ord k, Eq v)
  => v
  -- ^ look up this term
  -> k
  -- ^ starting from this node
  -> (n -> m a)
  -- ^ extract the desired data with this function
  -> DAG k [(v,v)] n
  -> m (DAG k None (v,a))
lookupAliasedTermM v0 k0 f d0 = lookupAliasedTerm' v0 k0 mempty where
  lookupAliasedTerm' v k d
    | Map.member k d = return d
    | otherwise = case Map.lookup k d0 of
        Nothing -> error "Could not find module"
        (Just (n, xs)) -> do
          let xs' = [ (k', [(v1,v2) | (v1,v2) <- vs, v2 == v])
                    | (k', vs) <- xs
                    , elem v (map snd vs)]
              edges' = map (\(k', _) -> (k', None)) xs'
          n' <- f n
          foldlM (\d2 (k2,v2) -> lookupAliasedTerm' v2 k2 d2)
                (Map.insert k ((v, n'), edges') d)
                (concat [zip (repeat k') (map fst vs) | (k', vs) <- xs'])
