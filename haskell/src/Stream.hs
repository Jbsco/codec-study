-- | The stream of the block codec, as ada/codec_main.adb writes it: frames in 32 bits; channels, depth and a
-- float flag in 8 bits each; for float input a mode and a scale per channel; a 32-bit byte length for every
-- block; then the blocks. Blocks encode in parallel with any block coder of the same format. Blocks that need
-- no samples from before them decode in parallel; then each channel decodes the rest in order.
module Stream (Prepared (..), prepare, encodeStream, decodeStream) where

import Data.Bits
import qualified Data.Vector as V
import qualified Data.Vector.Storable as S
import qualified Data.Vector.Unboxed as U
import Data.Maybe (fromMaybe)
import Data.Word (Word8)

import BlockCodec (maxBlock, maxHistory, usesHistory)
import Blocks (readWord32, word32)
import Parallel
import Wav

-- | Channels as the codec sees them: integers, float samples as integers over a power of two (mode 1), or
-- float bit patterns in the order-keeping map (mode 2).
data Prepared = Prepared
  { pFrames :: !Int
  , pDepth :: !Int
  , pFloat :: !Bool
  , pModes :: [(Int, Int)]
  , pCoded :: [U.Vector Int]
  }

prepare :: Audio -> Prepared
prepare a
  | isFloat a =
      let found = map toIntegers (channels a)
      in Prepared (frames a) (depth a) True [maybe (2, 0) (\(s, _) -> (1, s)) f | f <- found]
           [maybe c snd f | (f, c) <- zip found (channels a)]
  | otherwise = Prepared (frames a) (depth a) False [] (channels a)

-- | Integers I with sample = I / 2**S for every sample, when one S up to 31 fits them all.
toIntegers :: U.Vector Int -> Maybe (Int, U.Vector Int)
toIntegers xs = do
  fractions <- mapM (fraction . bitsOf) (U.toList xs)
  let s = maximum (0 : fractions)
  if s > 31 then Nothing else (,) s <$> U.mapM (scaled s . bitsOf) xs
  where
    bitsOf v = if v >= 0 then v else 2147483647 - v
    fields b = ((b `shiftR` 23) .&. 255, b .&. 8388607)
    fraction b
      | b == 2147483648 || e == 255 || (e == 0 && m /= 0) = Nothing
      | b .&. 2147483647 == 0 = Just 0
      | otherwise = Just (150 - e - countTrailingZeros (8388608 + m))
      where
        (e, m) = fields b
    scaled s b
      | b .&. 2147483647 == 0 = Just 0
      | up > 7 || mag >= 2147483648 = Nothing
      | otherwise = Just (if b >= 2147483648 then negate mag else mag)
      where
        (e, m) = fields b
        up = e - 150 + s
        mag = if up >= 0 then (8388608 + m) `shiftL` up else (8388608 + m) `shiftR` negate up

encodeStream :: (Int -> U.Vector Int -> U.Vector Int -> S.Vector Word8) -> Prepared -> S.Vector Word8
encodeStream enc p = S.concat (header : map (word32 . S.length) blocks ++ blocks)
  where
    n = pFrames p
    width = if pFloat p then 32 else pDepth p
    blocks = parMapNF (\(c, s) -> enc width (U.slice (max 0 (s - maxHistory)) (min s maxHistory) c) (U.slice s (min maxBlock (n - s)) c))
               [(c, s) | c <- pCoded p, s <- [0, maxBlock .. n - 1]]
    header = S.concat
      [ word32 n
      , S.fromList ([fromIntegral (length (pCoded p)), fromIntegral (pDepth p), if pFloat p then 1 else 0]
                    ++ concat [[fromIntegral m, fromIntegral s] | (m, s) <- pModes p])
      ]

decodeStream :: (Int -> U.Vector Int -> Int -> S.Vector Word8 -> U.Vector Int) -> S.Vector Word8 -> [U.Vector Int]
decodeStream dec v = parMapNF channel [0 .. nch - 1]
  where
    n = readWord32 v 0
    nch = fromIntegral (S.unsafeIndex v 4)
    float = S.unsafeIndex v 6 == 1
    width = if float then 32 else fromIntegral (S.unsafeIndex v 5)
    sizesAt = 7 + (if float then 2 * nch else 0)
    lengths = [min maxBlock (n - s) | s <- [0, maxBlock .. n - 1]]
    count = length lengths
    sizes = [readWord32 v (sizesAt + 4 * i) | i <- [0 .. nch * count - 1]]
    offsets = scanl (+) (sizesAt + 4 * nch * count) sizes
    blocks = V.fromList (zipWith (\o l -> S.slice o l v) offsets sizes)
    counts = V.fromList (concat (replicate nch lengths))
    alone = V.fromList (parMapNF (\i -> if usesHistory (blocks V.! i) then Nothing else Just (dec width U.empty (counts V.! i) (blocks V.! i)))
                                 [0 .. nch * count - 1])
    channel c = U.concat (reverse (go 0 []))
      where
        go b done
          | b == count = done
          | otherwise =
              let i = c * count + b
                  out = fromMaybe (dec width (recent done) (counts V.! i) (blocks V.! i)) (alone V.! i)
              in out `seq` go (b + 1) (out : done)
    recent done = U.concat (latest maxHistory done [])
    latest _ [] got = got
    latest need (b : bs) got
      | need <= 0 = got
      | U.length b >= need = U.drop (U.length b - need) b : got
      | otherwise = latest (need - U.length b) bs (b : got)
