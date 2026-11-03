-- | Audio input from WAV, RF64, Wave64 and AIFF at 8, 16, 24 and 32-bit integer and 32 or 64-bit float, one vector
-- per channel. Float samples become integers through their 32-bit patterns in an order-keeping map: a pattern with
-- the sign bit set becomes minus its other 31 bits, minus one. A 64-bit float file is read when every sample is
-- exactly a 32-bit float. Valid bits and the channel mask come from WAV's
-- extensible format header; a plain one gives the depth and no mask. AIFF's sample size may be any bit count,
-- left-justified in whole bytes, and gives the valid bits. The source description records the container and
-- every chunk in file order, as ada/wav_files.ads defines it, so a decoder can write the file back.
module Wav (Audio (..), readWav) where

import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import qualified Data.ByteString as B
import qualified Data.ByteString.Unsafe as BU
import qualified Data.Vector.Unboxed as U
import Data.Word (Word64, Word8)

import FloatBits (narrow)

data Audio = Audio
  { rate :: !Int
  , depth :: !Int
  , validBits :: !Int
  , channelMask :: !Int
  , isFloat :: !Bool
  , frames :: !Int
  , channels :: [U.Vector Int]
  , source :: Maybe B.ByteString
  , foreignDropped :: !Bool
  }

-- | Channel count, rate, depth, valid bits, channel mask and whether samples are float.
data Format = Format !Int !Int !Int !Int !Int !Bool

-- | A chunk of the file: its role (0 other, 1 format, 2 audio, 3 the RF64 size table), where its identifier is and
-- how long, the value of its own length field, and where its body is and how long.
data Entry = Entry !Int !Int !Int !Int !Int !Int

readWav :: FilePath -> IO Audio
readWav path = B.readFile path >>= either (fail . ((path ++ ": ") ++)) pure . parseAudio

-- | Wave64's chunk identifiers, as GUIDs.
w64Riff, w64Wave, w64Fmt, w64Data :: B.ByteString
w64Riff = B.pack [0x72, 0x69, 0x66, 0x66, 0x2E, 0x91, 0xCF, 0x11, 0xA5, 0xD6, 0x28, 0xDB, 0x04, 0xC1, 0x00, 0x00]
w64Wave = B.pack [0x77, 0x61, 0x76, 0x65, 0xF3, 0xAC, 0xD3, 0x11, 0x8C, 0xD1, 0x00, 0xC0, 0x4F, 0x8E, 0xDB, 0x8A]
w64Fmt = B.pack [0x66, 0x6D, 0x74, 0x20, 0xF3, 0xAC, 0xD3, 0x11, 0x8C, 0xD1, 0x00, 0xC0, 0x4F, 0x8E, 0xDB, 0x8A]
w64Data = B.pack [0x64, 0x61, 0x74, 0x61, 0xF3, 0xAC, 0xD3, 0x11, 0x8C, 0xD1, 0x00, 0xC0, 0x4F, 0x8E, 0xDB, 0x8A]

-- | The largest source description one metadata block takes.
maxSourceBytes :: Int
maxSourceBytes = 2 ^ (24 :: Int) - 1

parseAudio :: B.ByteString -> Either String Audio
parseAudio bs
  | tag 0 `elem` ["RIFF", "RF64", "BW64"] && tag 8 == "WAVE" =
      riff 12 Nothing Nothing Nothing [] >>= finish (if tag 0 == "RIFF" then 1 else if tag 0 == "RF64" then 2 else 3) (le 4 4)
  | slice 0 16 == w64Riff && slice 24 16 == w64Wave = wave64 40 Nothing Nothing [] >>= finish 4 (le 16 8)
  | tag 0 == "FORM" && tag 8 `elem` ["AIFF", "AIFC"] = aiff 12 Nothing Nothing [] >>= finish (if tag 8 == "AIFF" then 5 else 6) (be 4 4)
  | otherwise = Left "not a WAV, RF64, Wave64 or AIFF file"
  where
    n = B.length bs
    slice o k = B.take k (B.drop o bs)
    tag o = slice o 4
    fits o k = o >= 0 && o + k <= n
    u8 o = fromIntegral (BU.unsafeIndex bs o) :: Int
    le o k = foldr (\i acc -> acc `shiftL` 8 .|. u8 (o + i)) 0 [0 .. k - 1]
    be o k = foldl (\acc i -> acc `shiftL` 8 .|. u8 (o + i)) 0 [0 .. k - 1]
    entry role idAt idLen field body len = Entry role idAt idLen field body (max 0 (min len (n - body)))

    waveFormat o len
      | len < 16 || not (fits o 16) = Left "short format chunk"
      | not ((f == 1 && d `elem` [8, 16, 24, 32]) || (f == 3 && d `elem` [32, 64])) || ch < 1 || ch > 8 =
          Left "only 8 to 32-bit integer and 32 or 64-bit float PCM are read"
      | otherwise = Right (Format ch (le (o + 4) 4) d (if f == 3 then d else v) m (f == 3), False)
      where
        ext = le o 2 == 0xFFFE && len >= 24 && fits o 28
        f = if ext then le (o + 24) 2 else le o 2
        ch = le (o + 2) 2
        d = le (o + 14) 2
        v = if ext && le (o + 18) 2 >= 1 && le (o + 18) 2 <= d then le (o + 18) 2 else d
        m = if ext then le (o + 20) 4 else 0

    -- Each walker returns the format, where the samples are and how long, and the chunks in order.
    riff o fmt ds64 audio acc
      | not (fits o 8) = Right (fmt, audio, reverse acc)
      | tag o == "ds64" && len >= 16 && fits (o + 8) 16 = riff next fmt (Just (le (o + 16) 8)) audio (entry 3 o 4 len (o + 8) len : acc)
      | tag o == "fmt " = waveFormat (o + 8) len >>= \f -> riff next (Just f) ds64 audio (entry 1 o 4 len (o + 8) len : acc)
      | tag o == "data" && null audio = riff (o + 8 + dlen + dlen `mod` 2) fmt ds64 (Just (o + 8, dlen)) (entry 2 o 4 len (o + 8) 0 : acc)
      | otherwise = riff next fmt ds64 audio (entry 0 o 4 len (o + 8) len : acc)
      where
        len = le (o + 4) 4
        next = o + 8 + len + len `mod` 2
        dlen = if len == 0xFFFFFFFF then maybe len id ds64 else len

    wave64 o fmt audio acc
      | not (fits o 24) = Right (fmt, audio, reverse acc)
      | len < 24 = Left "bad Wave64 chunk length"
      | slice o 16 == w64Fmt = waveFormat (o + 24) (len - 24) >>= \f -> wave64 next (Just f) audio (entry 1 o 16 len (o + 24) (len - 24) : acc)
      | slice o 16 == w64Data && null audio = wave64 next fmt (Just (o + 24, len - 24)) (entry 2 o 16 len (o + 24) 0 : acc)
      | otherwise = wave64 next fmt audio (entry 0 o 16 len (o + 24) (len - 24) : acc)
      where
        len = le (o + 16) 8
        next = o + (len + 7) `quot` 8 * 8

    aiff o fmt audio acc
      | not (fits o 8) = Right (fmt, audio, reverse acc)
      | tag o == "COMM" && fits s 18 = comm >>= \f -> aiff next (Just f) audio (entry 1 o 4 len s len : acc)
      | tag o == "SSND" && fits s 8 && null audio = aiff (s + sound + sound `mod` 2) fmt (Just (s + 8 + be s 4, sound - 8 - be s 4)) (entry 2 o 4 len s (8 + be s 4) : acc)
      | otherwise = aiff next fmt audio (entry 0 o 4 len s len : acc)
      where
        s = o + 8
        len = be (o + 4) 4
        next = s + len + len `mod` 2
        sound = if len < 8 + be s 4 || len > n - s then n - s else len
        bits = be (s + 6) 2
        expo = be (s + 8) 2 .&. 0x7FFF - 16383
        mantissa = fromIntegral (be (s + 10) 4) `shiftL` 32 .|. fromIntegral (be (s + 14) 4) :: Word64
        kind = if tag 8 == "AIFC" && len >= 22 && fits (s + 18) 4 then tag (s + 18) else "NONE"
        float = kind `elem` ["fl32", "FL32", "fl64", "FL64"]
        ch = be s 2
        d = if kind `elem` ["fl64", "FL64"] then 64 else if float then 32 else (bits + 7) `quot` 8 * 8
        sampleRate = if expo >= 0 && expo <= 63 then fromIntegral (mantissa `shiftR` (63 - expo)) else 0
        comm
          | kind `notElem` ["NONE", "twos", "sowt", "fl32", "FL32", "fl64", "FL64"] || (float && bits /= d) || d `notElem` [8, 16, 24, 32, 64]
            || bits == 0 || ch < 1 || ch > 8 = Left "only 1 to 32-bit integer and 32 or 64-bit float AIFF are read"
          | otherwise = Right (Format ch sampleRate d (if float then d else bits) 0 float, kind == "sowt")

    finish kind sizeField (Just (f, little), Just (start, len), entries) =
      let isAiff = kind >= 5
          (described, dropped) = describe kind sizeField (take 1024 entries)
          a = samples f (isAiff && not little) isAiff start len described dropped
      in if any (U.elem inexact) (channels a)
           then Left "64-bit float samples that are not exactly 32-bit float are not read"
           else Right a
    finish _ _ (Nothing, _, _) = Left "audio data before its format"
    finish _ _ (_, Nothing, _) = Left "no audio chunk"

    -- The source description, big-endian: container, its own size field, chunk count, then each chunk's role,
    -- identifier length, identifier, length field, body length and body. Chunks other than format, audio and the
    -- size table are left out when all of them would not fit one metadata block.
    describe :: Int -> Int -> [Entry] -> (Maybe B.ByteString, Bool)
    describe kind sizeField entries
      | size keepAll <= maxSourceBytes = (Just (bytes keepAll), False)
      | size kept <= maxSourceBytes = (Just (bytes kept), True)
      | otherwise = (Nothing, True)
      where
        keepAll = entries
        kept = [e | e@(Entry role _ _ _ _ _) <- entries, role /= 0]
        size es = 11 + sum [14 + idLen + len | Entry _ _ idLen _ _ len <- es]
        bytes es = B.concat (B.pack (int 1 kind ++ int 8 sizeField ++ int 2 (length es)) : concatMap one es)
        one (Entry role idAt idLen field body len) =
          [B.pack (int 1 role ++ int 1 idLen), slice idAt idLen, B.pack (int 8 field ++ int 4 len), slice body len]
        int :: Int -> Int -> [Word8]
        int k v = [fromIntegral (v `shiftR` (8 * i)) | i <- [k - 1, k - 2 .. 0]]

    -- A marker for a 64-bit float sample that is not exactly a 32-bit one, outside every 32-bit pattern's range.
    inexact = -(2 ^ (40 :: Int)) :: Int

    samples (Format ch r d v m float) big signedBytes start len =
      let width = d `div` 8
          half = 1 `shiftL` (min d 32 - 1) :: Int
          single raw = if raw >= 2147483648 then 2147483647 - raw else raw
          value raw
            | float && width == 8 = maybe inexact (single . fromIntegral) (narrow (fromIntegral raw))
            | float = single raw
            | width == 1 && not signedBytes = raw - 128
            | raw >= half = raw - 2 * half
            | otherwise = raw
          sample c i =
            let o = start + (i * ch + c) * width
            in value (if big then be o width else le o width)
          count = min (min len (n - start) `div` (width * ch)) (3600 * r)
      in Audio r d v m float count [U.generate count (sample c) | c <- [0 .. ch - 1]]
