-- | The block codec with the Haskell stream and parallel map around the Ada and SPARK block coder.
module Main (main) where

import Data.Maybe (listToMaybe)
import GHC.Conc (getNumCapabilities)
import System.Environment (getArgs)
import Text.Printf (printf)

import Report
import SparkFFI
import Wav

main :: IO ()
main = do
  args <- getArgs
  case args of
    path : rest | length rest <= 1 -> do
      audio <- readWav path
      caps <- getNumCapabilities
      printf "%s\n %d capabilities; bits per sample, side information included:\n" path caps
      blockLine "Block codec, Haskell + SPARK" sparkEncode sparkDecode (maybe 4 read (listToMaybe rest)) audio
    _ -> putStrLn "usage: huffman-audio-hybrid <file.wav> [level 0 to 4]"
