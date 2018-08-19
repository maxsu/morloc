{-|
Module      : Morloc.Util
Description : Miscellaneous small utility functions
Copyright   : (c) Zebulun Arendsee, 2018
License     : GPL-3
Maintainer  : zbwrnz@gmail.com
Stability   : experimental
-}

module Morloc.Util
(
    show'
  , ifelse
  , conmap
  , unique
  , sort
  , repeated
  , indent
  , maybe2bool
  , either2bool
  , maybeOne
  , zipWithOrDie
  , initChain
) where

import Morloc.Operators

import qualified Data.List as DL
import qualified Data.Text as DT
import qualified Control.Monad as CM

show' :: Show a => a -> DT.Text
show' = DT.pack . show

conmap :: (a -> [b]) -> [a] -> [b]
conmap f = concat . map f

ifelse :: Bool -> a -> a -> a
ifelse True  x _ = x
ifelse False _ y = y

unique :: Eq a => [a] -> [a]
unique = DL.nub

sort :: Ord a => [a] -> [a]
sort = DL.sort

repeated :: Ord a => [a] -> [a]
repeated xs = [y | (y:(_:_)) <- (DL.group . DL.sort) xs]

indent :: Int -> DT.Text -> DT.Text
indent i s
  | i <= 0 = s
  -- TODO: this the String -> Text transform here is slow and unnecessary
  | otherwise = DT.unlines . map ((<>) (DT.pack (take i (repeat ' ')))) . DT.lines $ s

maybe2bool :: Maybe a -> Bool
maybe2bool (Just _) = True
maybe2bool Nothing = False

either2bool :: Either a b -> Bool
either2bool (Left _) = False
either2bool (Right _) = True

maybeOne :: [a] -> Maybe a
maybeOne [x] = Just x
maybeOne _  = Nothing

zipWithOrDie :: (a -> b -> c) -> [a] -> [b] -> [c]
zipWithOrDie f xs ys
  | length xs == length ys = zipWith f xs ys
  | otherwise = error "Expected lists of equal length"

initChain
  :: CM.MonadPlus m
  => m a
  -> [(m a, Maybe (a -> m a))]
  -> m a
initChain x [] = x
initChain mempty ((x , _      ):fs) = initChain x         fs
initChain x      ((_ , Just g ):fs) = initChain (x >>= g) fs
initChain x      ((_ , Nothing):fs) = initChain x         fs
