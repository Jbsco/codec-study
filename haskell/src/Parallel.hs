-- | Deterministic parallel map over pure functions with GHC sparks.
module Parallel (parMapNF) where

import Control.DeepSeq (NFData, force)
import GHC.Conc (par, pseq)

-- | Map with one spark per element. Each result is fully evaluated, so a spark does all of its work.
parMapNF :: NFData b => (a -> b) -> [a] -> [b]
parMapNF f xs = foldr par () ys `pseq` ys
  where
    ys = map (force . f) xs
