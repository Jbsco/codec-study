-- | WAV input at 8, 16, 24 and 32-bit integer and 32-bit float, one vector per channel. Float samples become
-- integers through their bit patterns in an order-keeping map: a pattern with the sign bit set becomes minus
-- its other 31 bits, minus one.
module Wav (Audio (..), readWav) where

import Data.Bits (shiftL, (.|.))
import qualified Data.ByteString as B
import qualified Data.ByteString.Unsafe as BU
import qualified Data.Vector.Unboxed as U

data Audio = Audio
  { rate :: !Int
  , depth :: !Int
  , isFloat :: !Bool
  , frames :: !Int
  , channels :: [U.Vector Int]
  }

readWav :: FilePath -> IO Audio
readWav path = do
  bs <- B.readFile path
  let u8 o = fromIntegral (BU.unsafeIndex bs o) :: Int
      u16 o = u8 o .|. (u8 (o + 1) `shiftL` 8)
      u32 o = u16 o .|. (u16 (o + 2) `shiftL` 16)
      tag o = B.take 4 (B.drop o bs)
      next o = let n = u32 (o + 4) in o + 8 + n + n `mod` 2
      chunks o fmt
        | o + 8 > B.length bs = Left "no data chunk"
        | tag o == "fmt " =
            let f = if u16 (o + 8) == 0xFFFE then u16 (o + 32) else u16 (o + 8)
            in chunks (next o) (Just (f, u16 (o + 10), u32 (o + 12), u16 (o + 22)))
        | tag o == "data", Just (f, ch, r, d) <- fmt =
            if (f == 1 && d `elem` [8, 16, 24, 32]) || (f == 3 && d == 32)
              then Right (samples f ch r d (o + 8) (u32 (o + 4)))
              else Left "only 8 to 32-bit integer and 32-bit float PCM are read"
        | otherwise = chunks (next o) fmt
      samples f ch r d start len =
        let width = d `div` 8
            half = 1 `shiftL` (d - 1) :: Int
            value raw
              | f == 3 = if raw >= half then half - 1 - raw else raw
              | width == 1 = raw - 128
              | raw >= half = raw - 2 * half
              | otherwise = raw
            sample c i =
              let o = start + (i * ch + c) * width
              in value (foldr (\k acc -> (acc `shiftL` 8) .|. u8 (o + k)) 0 [0 .. width - 1])
            n = len `div` (width * ch)
        in Audio r d (f == 3) n [U.generate n (sample c) | c <- [0 .. ch - 1]]
  if tag 0 /= "RIFF" || tag 8 /= "WAVE"
    then fail (path ++ ": not a WAV file")
    else either (fail . ((path ++ ": ") ++)) pure (chunks 12 Nothing)
