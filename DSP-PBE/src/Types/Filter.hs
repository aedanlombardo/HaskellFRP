{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE NoMonomorphismRestriction #-}

{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleInstances #-}

{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE MultiWayIf #-}

module Types.Filter where

import Vivid

import qualified Data.Map as M
import qualified Data.Tree as T
import Data.Tree 
import Data.Maybe

import Data.List
import Data.Functor.Classes
import Data.Data
import Control.Monad.Zip

import GHC.Generics
import Control.Lens

import Types.DSPNode

import Text.Printf

import Debug.Trace

-- | A DSP Program is a structure of DSPNodes, each with an Id
--   TODO relax from Tree to Directed Acyclic Graph
type Filter = T.Tree DSPNodeL

drawFilter :: Filter -> String
drawFilter = 
  drawTree. fmap (show. nodeContent)


-- | check that two filters have the same structure, ignoring parameters
-- TODO can this be written without so much repetition?
sameStructure :: Filter -> Filter -> Bool
sameStructure f1 f2 = fmap (toConstr. nodeContent) f1 == fmap (toConstr. nodeContent) f2

-- Tree has Ord1, which gives us liftCompare. No clue what is happening here really
-- If there are any stranger bugs with tree operations, this is probably the problem
instance Ord Filter where
  compare = liftCompare (compare)

-- A log of the best filter for each structure
type FilterLog = M.Map Filter Double

{-showAmp amp = "amp@"++(printf "%.2f" $ ampScale amp)
showFreq freq = "freq@" ++ (printf "%.0f" $ freqScale freq)
showFreqP freq = "freq@" ++ (printf "%.0f" $ freqScalePitchShift freq)
showDelay d = "delay@" ++ (printf "%.2f" $ delayScale d)
-}

checkStructureThen :: Filter -> Filter -> a -> a-> a
checkStructureThen f1 f2 defaultVal a = 
  if sameStructure f1 f2
  then a
  else 
     -- TODO this shouldn't happen, 
     -- but for now we just result defaultVal (whatever that is)
     -- so that the program doesnt crash
     defaultVal -- error "can only calculate compare filters on equivelant structures"

filterDiff :: Filter -> Filter -> Double
filterDiff f1 f2 = let
   nodeDiff n1 n2 = sum $ (zipWith (\p1 p2 -> abs (snd p1 - snd p2)) (getParams $ nodeContent n1) (getParams $ nodeContent n2))
   diffTree = liftA2 nodeDiff f1 f2
 in 
  checkStructureThen f1 f2 0 $ sum diffTree

-- | which field changed between two filters
--   if more than one change, returns only the first one found
filterFieldChange :: Filter -> Filter -> [Char]
filterFieldChange f1 f2 = let
  -- TODO change 0.0000001 to something else
   fieldDiff p1 p2 = if (abs (snd p1-snd p2)) < 0.00000001 then Nothing else Just $ fst p1
   nodeDiff n1 n2 = zipWith fieldDiff (getParams $ nodeContent n1) (getParams $ nodeContent n2)
   diffTree :: T.Tree ([Maybe String])
   diffTree = zipTree nodeDiff f1 f2
 in 
   case catMaybes $ concat $ T.flatten diffTree of
   []  -> "No change"
   [x] -> x
   xs  -> head xs --error $ "Multiple fields changed at once"++ show diffTree --this shouldnt really happen, but for now just give the head of the list

zipTree :: (a -> b -> c) -> T.Tree a -> T.Tree b -> T.Tree c
zipTree f t1 t2 = Node {
    rootLabel = f (rootLabel t1) (rootLabel t2)
  , subForest = zipSubForest f (subForest t1) (subForest t2)
  }

zipSubForest :: (a -> b -> c) -> [T.Tree a] -> [T.Tree b] -> [T.Tree c]
zipSubForest f [] [] = []
zipSubForest f (x:xs) (y:ys) = (zipTree f x y): zipSubForest f xs ys
zipSubForest f [] _ = error "Structural mismatch"
zipSubForest f _ [] = error "structural mismatch"

-- | find a node in f that is the same DSPNode as n
--   if no such node is found, give back n
findSameNode :: Filter -> DSPNodeL -> DSPNodeL
findSameNode f n = case catMaybes $ foldr (\n1 ns -> (if sameConstructor (nodeContent n1) (nodeContent n) then Just n1 else Nothing):ns) [] f of
  [] -> n
  xs -> head xs

--implements feature scaling so during GD our thetas are -1<t<1
--we only scale them back to the appropriate values when we need to apply theatas in a filter
toVivid :: Filter -> SDBody' '[] Signal -> SDBody' '[] Signal
toVivid f = case T.subForest f of
  [] -> nodeToVivid $ nodeContent $ T.rootLabel f
  ns -> sequentialCompose (nodeToVivid $ nodeContent $ T.rootLabel f) ns
 where
  sequentialCompose :: (SDBody' '[] Signal -> SDBody' '[] Signal) -> 
                       [Filter] -> 
                        SDBody' '[] Signal -> SDBody' '[] Signal
  sequentialCompose n ns = 
    (\bufs -> n $ (parallelCompose ns) bufs)
  parallelCompose :: [Filter] -> (SDBody' '[] Signal -> SDBody' '[] Signal)
  parallelCompose ns = 
    foldr (\thisNode composedNodes -> 
                (\bufs -> (composedNodes bufs) ~+ ((toVivid thisNode) bufs)))
          id ns

nodeToVivid :: DSPNode -> SDBody' '[] Signal -> SDBody' '[] Signal
nodeToVivid = \case
  ID a                   -> (\bufs -> (ampScale a::Float) ~* bufs)
  HPF t a                -> (\bufs -> (ampScale a::Float) ~* hpf (freq_ (freqScale t::Float), in_ bufs))
  LPF t a                -> (\bufs -> (ampScale a::Float) ~* lpf (freq_ (freqScale t::Float), in_ bufs))
  PitchShift t a         -> (\bufs -> (ampScale a::Float) ~* freqShift (freq_ (freqScalePitchShift t::Float), in_ bufs)) -- there is also pitchShift in vivid, but it is more complex
  WhiteNoise a           -> (\bufs -> (ampScale a::Float) ~* whiteNoise) --TODO mix bufs into output
  --Ringz f d a            -> (\bufs -> (ampScale a::Float) ~* ringz (freq_ (freqScale f::Float), decaySecs_ (delayScale d::Float), in_ bufs))
  FreeVerb f d a         -> (\bufs -> (ampScale a::Float) ~* freeVerb (mix_ (freqScale f::Float), room_ (delayScale d::Float), in_ bufs))

-- | Given a filter structure, extract the theta selctors that we need to do parameter synthesis
extractThetaUpdaters :: Filter -> [Filter -> (Double -> Double) -> Filter]
extractThetaUpdaters filter = 
  foldr ((++). getUpdater) [] filter

-- | Using the nodeId, we can get a function that updates the particular node of interest
--   this allows us to do SGD with multiple copies of the same DSPNode in a single Filter
getUpdater :: DSPNodeL -> [Filter -> (Double -> Double) -> Filter]
getUpdater dspNode = let
  updater :: _ -> _ -> Filter -> (Double -> Double) -> Filter
  updater nodeType nodeParam = (\ts f -> fmap (\n -> if nodeId n == nodeId dspNode then n{nodeContent = nodeType $ f nodeParam} else n) ts)
 in 
  case nodeContent dspNode of 
    ID a                   -> [ updater ID a]
    HPF t a                -> [ updater (\newT -> HPF newT a) t
                              , updater (\newA -> HPF t newA) a] 
    LPF t a                -> [ updater (\newT -> LPF newT a) t
                              , updater (\newA -> LPF t newA) a]
    PitchShift t a         -> [ updater (\newT -> PitchShift newT a) t
                              , updater (\newA -> PitchShift t newA) a]
    WhiteNoise a           -> [ updater WhiteNoise a]
    FreeVerb t d a         -> [ updater (\newT -> FreeVerb newT d a) t
                              , updater (\newD -> FreeVerb t newD a) d
                              , updater (\newA -> FreeVerb t d newA) a]

