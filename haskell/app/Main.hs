-- | Code a WAV file with each parallel scheme, decode it again and compare every sample. Prints the size, a
-- hash of the coded stream, and the wall time of each step. With --block, only the block codec runs.
module Main (main) where

import Control.DeepSeq (force)
import Control.Exception (evaluate)
import Control.Monad (forM_)
import qualified Data.Vector.Storable as S
import qualified Data.Vector.Unboxed as U
import Data.Word (Word8)
import GHC.Clock (getMonotonicTime)
import GHC.Conc (getNumCapabilities)
import System.Environment (getArgs)
import Text.Printf (printf)

import BlockCodec (decodeBlock, encodeBlock)
import Blocks
import Report
import Tiers
import Wav

type Scheme = (String, [U.Vector Int] -> S.Vector Word8, S.Vector Word8 -> [U.Vector Int])

main :: IO ()
main = do
  args <- getArgs
  case args of
    [path] -> run path
    [path, "--block"] -> readWav path >>= blockLine "Block codec, Haskell" encodeBlock decodeBlock 4
    [path, "--block", level] -> readWav path >>= blockLine "Block codec, Haskell" encodeBlock decodeBlock (read level)
    _ -> putStrLn "usage: huffman-audio <file.wav> [--block [level 0 to 4]]"

run :: FilePath -> IO ()
run path = do
  audio <- readWav path
  caps <- getNumCapabilities
  chans <- evaluate (force (channels audio))
  let total = frames audio * length chans
      d = depth audio
      f = isFloat audio
      schemes :: [Scheme]
      schemes =
        [ ("Fixed predictor, Rice per block", encodeBlocks Rice d f, decodeBlocks Rice)
        , ("Fixed predictor, bit-length Huffman per block", encodeBlocks BitLength d f, decodeBlocks BitLength)
        , ("Fixed predictor, shorter of the two per block", encodeBlocks Shorter d f, decodeBlocks Shorter)
        , ("Tiers, pairs, offset from mean, bit-length per chunk", encodeTiers d f, decodeTiers)
        ]
  printf "%s\n %d-bit%s, %d Hz, %d channels, %d s, %d capabilities; bits per sample, side information included:\n"
    path d (if f then " float" else "" :: String) (rate audio) (length chans) (frames audio `quot` rate audio) caps
  forM_ schemes $ \(name, enc, dec) -> do
    t0 <- getMonotonicTime
    coded <- evaluate (force (enc chans))
    t1 <- getMonotonicTime
    out <- evaluate (force (dec coded))
    t2 <- getMonotonicTime
    printf "  %-52s %6.2f  %s, hash %016x, encode %5.2f s, decode %5.2f s\n" name
      (8 * fromIntegral (S.length coded) / fromIntegral total :: Double)
      (if out == chans then "round trip OK" else "ROUND TRIP FAILED" :: String) (fnv1a coded) (t1 - t0) (t2 - t1)
  blockLine "Block codec, Haskell" encodeBlock decodeBlock 4 audio
