-- | Run one block coder over a file and print one line: bits per sample, round trip, a hash of the stream, and
-- the wall time of each step.
module Report (fnv1a, blockLine) where

import Control.DeepSeq (force)
import Control.Exception (evaluate)
import Data.Bits (xor)
import qualified Data.Vector.Storable as S
import qualified Data.Vector.Unboxed as U
import Data.Word (Word64, Word8)
import GHC.Clock (getMonotonicTime)
import Text.Printf (printf)

import Stream
import Wav

-- | FNV-1a over the coded bytes; equal hashes show that two coders, or two core counts, write the same stream.
fnv1a :: S.Vector Word8 -> Word64
fnv1a = S.foldl' (\h b -> (h `xor` fromIntegral b) * 1099511628211) 14695981039346656037

blockLine :: String -> (Int -> U.Vector Int -> U.Vector Int -> S.Vector Word8) -> (Int -> U.Vector Int -> Int -> S.Vector Word8 -> U.Vector Int)
          -> Audio -> IO ()
blockLine name enc dec audio = do
  let p = prepare audio
  coded0 <- evaluate (force (pCoded p))
  let total = pFrames p * length coded0
  t0 <- getMonotonicTime
  stream <- evaluate (force (encodeStream enc p))
  t1 <- getMonotonicTime
  out <- evaluate (force (decodeStream dec stream))
  t2 <- getMonotonicTime
  printf "  %-52s %6.2f  %s, hash %016x, encode %5.2f s, decode %5.2f s\n" name
    (8 * fromIntegral (S.length stream) / fromIntegral total :: Double)
    (if out == coded0 then "round trip OK" else "ROUND TRIP FAILED" :: String) (fnv1a stream) (t1 - t0) (t2 - t1)
