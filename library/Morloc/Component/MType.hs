{-# LANGUAGE OverloadedStrings, TemplateHaskell, QuasiQuotes #-}

{-|
Module      : Morloc.Component.MType
Description : Build manifolds for code generation from a SPARQL endpoint.
Copyright   : (c) Zebulun Arendsee, 2018
License     : GPL-3
Maintainer  : zbwrnz@gmail.com
Stability   : experimental
-}

module Morloc.Component.MType (fromSparqlDb) where

import Morloc.Types
import Morloc.Operators
import Morloc.Quasi
import qualified Morloc.Triple as M3
import qualified Morloc.Component.Util as MCU

import Text.PrettyPrint.Leijen.Text hiding ((<$>), (<>))
import Morloc.Database.HSparql.Connection
import qualified Data.Map.Strict as Map
import qualified Data.List.Extra as DLE
import qualified Data.Foldable as DF
import qualified Data.Text as DT

type ParentData =
  ( DT.Text       -- type (e.g. mlc:functionType or mlc:atomicGeneric)
  , Maybe DT.Text -- top-level name of the type (e.g. "List" or "Int")
  , Maybe Key     -- type id of the output if this is a function
  , Maybe Lang    -- type language ("Morloc" for a general type)
  , Maybe Name    -- typename from a typeDeclaration statement
  , [Name]        -- list of properties (e.g. "packs")
  )

instance MShow MType where
  mshow (MDataType _ n []) = text' n
  mshow (MDataType _ n ts) = parens $ hsep (text' n:(map mshow ts))
  mshow (MFuncType _ ts o) = parens $
    (hcat . punctuate ", ") (map mshow ts) <> " -> " <> mshow o

fromSparqlDb :: SparqlEndPoint -> IO (Map.Map Key MType)
fromSparqlDb = MCU.simpleGraph toMType getParentData id sparqlQuery

getParentData :: [Maybe DT.Text] -> ParentData 
getParentData [Just t, v, o, l, n, ps] = (t, v, o, l, n, properties) where
  properties = DF.concat . fmap (DT.splitOn ",") $ ps
getParentData x = error ("Unexpected SPARQL result: " ++ show x)

toMType :: Map.Map Key (ParentData, [Key]) -> Key -> MType
toMType h k = toMType' (Map.lookup k h) where
  toMType' (Just ((t, v, o, l, n, ps), xs)) = case makeMeta l n ps of
    meta -> toMType'' meta v o xs

  toMType'' meta (Just v) _ xs = MDataType meta v (map (toMType h) xs)
  toMType'' meta _ (Just o) xs = MFuncType meta (map (toMType h) xs) (toMType h o)

  makeMeta :: Maybe Lang -> Maybe Name -> [Name] -> MTypeMeta
  makeMeta l n ps = MTypeMeta {
        metaName = n
      , metaProp = ps
      , metaLang = l
    }

sparqlQuery :: SparqlEndPoint -> IO [[Maybe DT.Text]]
sparqlQuery = [sparql|
PREFIX mlc: <http://www.morloc.io/ontology/000/>
PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
PREFIX mid: <http://www.morloc.io/XXX/mid/>
SELECT ?id ?element ?child ?type ?v ?output ?lang ?typename
       (GROUP_CONCAT(?property; separator=",") AS ?properties)
WHERE {
    ?id rdf:type mlc:type ;
        rdf:type ?type .
    FILTER(?type != mlc:type)
    OPTIONAL { ?id rdf:value ?v . }
    OPTIONAL {
        ?id ?element ?child .
        FILTER(REGEX(STR(?element), "_[0-9]+$", "i"))
    }
    OPTIONAL { ?id mlc:output ?output . }
    OPTIONAL { ?id mlc:property/rdf:value ?property . }
    OPTIONAL {
        ?typedec rdf:type mlc:typeDeclaration ;
                 mlc:lang ?lang ;
                 mlc:lhs ?typename ; 
                 mlc:rhs ?id .
    }
}
GROUP BY ?id ?element ?child ?type ?v ?output ?lang ?typename
ORDER BY ?id ?element
|] 