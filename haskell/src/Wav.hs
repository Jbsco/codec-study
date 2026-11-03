-- | Audio input from WAV, RF64, Wave64 and AIFF at 8, 16, 24 and 32-bit integer and 32-bit float, one vector per
-- channel. Float samples become integers through their bit patterns in an order-keeping map: a pattern with the
-- sign bit set becomes minus its other 31 bits, minus one. Valid bits and the channel mask come from WAV's
-- extensible format header; a plain one gives the depth and no mask. AIFF's sample size may be any bit count,
-- left-justified in whole bytes, and gives the valid bits.
module Wav (Audio (..), readWav) where

import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import qualified Data.ByteString as B
import qualified Data.ByteString.Unsafe as BU
import qualified Data.Vector.Unboxed as U
import Data.Word (Word64)

data Audio = Audio
  { rate :: !Int
  , depth :: !Int
  , validBits :: !Int
  , channelMask :: !Int
  , isFloat :: !Bool
  , frames :: !Int
  , channels :: [U.Vector Int]
  }

-- | Channel count, rate, depth, valid bits, channel mask and whether samples are float.
data Format = Format !Int !Int !Int !Int !Int !Bool

readWav :: FilePath -> IO Audio
readWav path = B.readFile path >>= either (fail . ((path ++ ": ") ++)) pure . parseAudio

-- | Wave64's chunk identifiers, as GUIDs.
w64Riff, w64Wave, w64Fmt, w64Data :: B.ByteString
w64Riff = B.pack [0x72, 0x69, 0x66, 0x66, 0x2E, 0x91, 0xCF, 0x11, 0xA5, 0xD6, 0x28, 0xDB, 0x04, 0xC1, 0x00, 0x00]
w64Wave = B.pack [0x77, 0x61, 0x76, 0x65, 0xF3, 0xAC, 0xD3, 0x11, 0x8C, 0xD1, 0x00, 0xC0, 0x4F, 0x8E, 0xDB, 0x8A]
w64Fmt = B.pack [0x66, 0x6D, 0x74, 0x20, 0xF3, 0xAC, 0xD3, 0x11, 0x8C, 0xD1, 0x00, 0xC0, 0x4F, 0x8E, 0xDB, 0x8A]
w64Data = B.pack [0x64, 0x61, 0x74, 0x61, 0xF3, 0xAC, 0xD3, 0x11, 0x8C, 0xD1, 0x00, 0xC0, 0x4F, 0x8E, 0xDB, 0x8A]

parseAudio :: B.ByteString -> Either String Audio
parseAudio bs
  | tag 0 `elem` ["RIFF", "RF64", "BW64"] && tag 8 == "WAVE" = riff 12 Nothing Nothing
  | slice 0 16 == w64Riff && slice 24 16 == w64Wave = wave64 40 Nothing
  | tag 0 == "FORM" && tag 8 `elem` ["AIFF", "AIFC"] = aiff 12 Nothing
  | otherwise = Left "not a WAV, RF64, Wave64 or AIFF file"
  where
    n = B.length bs
    slice o k = B.take k (B.drop o bs)
    tag o = slice o 4
    fits o k = o >= 0 && o + k <= n
    u8 o = fromIntegral (BU.unsafeIndex bs o) :: Int
    le o k = foldr (\i acc -> acc `shiftL` 8 .|. u8 (o + i)) 0 [0 .. k - 1]
    be o k = foldl (\acc i -> acc `shiftL` 8 .|. u8 (o + i)) 0 [0 .. k - 1]

    waveFormat o len
      | len < 16 || not (fits o 16) = Left "short format chunk"
      | not ((f == 1 && d `elem` [8, 16, 24, 32]) || (f == 3 && d == 32)) || ch < 1 || ch > 8 =
          Left "only 8 to 32-bit integer and 32-bit float PCM are read"
      | otherwise = Right (Format ch (le (o + 4) 4) d v m (f == 3))
      where
        ext = le o 2 == 0xFFFE && len >= 24 && fits o 28
        f = if ext then le (o + 24) 2 else le o 2
        ch = le (o + 2) 2
        d = le (o + 14) 2
        v = if ext && le (o + 18) 2 >= 1 && le (o + 18) 2 <= d then le (o + 18) 2 else d
        m = if ext then le (o + 20) 4 else 0

    riff o fmt ds64
      | not (fits o 8) = Left "no data chunk"
      | tag o == "ds64" && len >= 16 && fits (o + 8) 16 = riff next fmt (Just (le (o + 16) 8))
      | tag o == "fmt " = waveFormat (o + 8) len >>= \f -> riff next (Just f) ds64
      | tag o == "data" = withFormat fmt (\f -> samples f False False (o + 8) (if len == 0xFFFFFFFF then maybe len id ds64 else len))
      | otherwise = riff next fmt ds64
      where
        len = le (o + 4) 4
        next = o + 8 + len + len `mod` 2

    wave64 o fmt
      | not (fits o 24) = Left "no data chunk"
      | len < 24 = Left "bad Wave64 chunk length"
      | slice o 16 == w64Fmt = waveFormat (o + 24) (len - 24) >>= \f -> wave64 next (Just f)
      | slice o 16 == w64Data = withFormat fmt (\f -> samples f False False (o + 24) (len - 24))
      | otherwise = wave64 next fmt
      where
        len = le (o + 16) 8
        next = o + (len + 7) `quot` 8 * 8

    aiff o fmt
      | not (fits o 8) = Left "no SSND chunk"
      | tag o == "COMM" && fits s 18 = comm >>= \f -> aiff next (Just f)
      | tag o == "SSND" && fits s 8 = withFormat fmt (\(f, little) -> samples f (not little) True (s + 8 + be s 4) (len - 8 - be s 4))
      | otherwise = aiff next fmt
      where
        s = o + 8
        len = be (o + 4) 4
        next = s + len + len `mod` 2
        bits = be (s + 6) 2
        expo = be (s + 8) 2 .&. 0x7FFF - 16383
        mantissa = fromIntegral (be (s + 10) 4) `shiftL` 32 .|. fromIntegral (be (s + 14) 4) :: Word64
        kind = if tag 8 == "AIFC" && len >= 22 && fits (s + 18) 4 then tag (s + 18) else "NONE"
        float = kind `elem` ["fl32", "FL32"]
        ch = be s 2
        d = if float then 32 else (bits + 7) `quot` 8 * 8
        sampleRate = if expo >= 0 && expo <= 63 then fromIntegral (mantissa `shiftR` (63 - expo)) else 0
        comm
          | kind `notElem` ["NONE", "twos", "sowt", "fl32", "FL32"] || (float && bits /= 32) || d `notElem` [8, 16, 24, 32]
            || bits == 0 || ch < 1 || ch > 8 = Left "only 1 to 32-bit integer and 32-bit float AIFF are read"
          | otherwise = Right (Format ch sampleRate d (if float then 32 else bits) 0 float, kind == "sowt")

    withFormat :: Maybe a -> (a -> Audio) -> Either String Audio
    withFormat fmt k = maybe (Left "audio data before its format") (Right . k) fmt

    samples (Format ch r d v m float) big signedBytes start len =
      let width = d `div` 8
          half = 1 `shiftL` (d - 1) :: Int
          value raw
            | float = if raw >= half then half - 1 - raw else raw
            | width == 1 && not signedBytes = raw - 128
            | raw >= half = raw - 2 * half
            | otherwise = raw
          sample c i =
            let o = start + (i * ch + c) * width
            in value (if big then be o width else le o width)
          count = min (min len (n - start) `div` (width * ch)) (3600 * r)
      in Audio r d v m float count [U.generate count (sample c) | c <- [0 .. ch - 1]]
