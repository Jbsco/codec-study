-- | The block codec with the Haskell stream and parallel map around the Ada and SPARK block coder.
module Main (main) where

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
    [path] -> do
      audio <- readWav path
      caps <- getNumCapabilities
      printf "%s\n %d capabilities; bits per sample, side information included:\n" path caps
      blockLine "Block codec, Haskell + SPARK" sparkEncode sparkDecode audio
    _ -> putStrLn "usage: huffman-audio-hybrid <file.wav>"
