-- | Tiers of pairs: the first sample of each pair forms the next tier, and the second is stored as its offset
-- from the mean of the first samples of its pair and the next. The offsets of each tier are coded in chunks of
-- 4096 with bit-length Huffman codes; chunks encode in parallel, and decode in parallel within a tier.
module Tiers (encodeTiers, decodeTiers) where

import Control.Monad.ST (runST)
import Data.Bits
import qualified Data.Vector.Storable as S
import qualified Data.Vector.Storable.Mutable as SM
import qualified Data.Vector.Unboxed as U
import Data.Word (Word8)

import Bits
import Blocks (readWord32, word32)
import Coding
import Parallel

chunkSize :: Int
chunkSize = 4096

split :: U.Vector Int -> (U.Vector Int, U.Vector Int)
split s = (U.generate g offset, U.generate g anchor U.++ U.drop (2 * g) s)
  where
    g = U.length s `quot` 2
    anchor j = U.unsafeIndex s (2 * j)
    following j = if j < g - 1 then anchor (j + 1) else anchor j
    offset j = U.unsafeIndex s (2 * j + 1) - (anchor j + following j) `quot` 2

join :: Int -> U.Vector Int -> U.Vector Int -> U.Vector Int
join len next d = U.generate len value
  where
    g = len `quot` 2
    anchor j = U.unsafeIndex next j
    following j = if j < g - 1 then anchor (j + 1) else anchor j
    value i
      | i >= 2 * g = U.unsafeIndex next (i - g)
      | even i = anchor (i `quot` 2)
      | otherwise = let j = i `quot` 2 in U.unsafeIndex d j + (anchor j + following j) `quot` 2

-- | The length of each tier from the finest, ending at the first of two samples or fewer.
lengths :: Int -> [Int]
lengths n = n : if n <= 2 then [] else lengths (n `quot` 2 + n `rem` 2)

-- | The offsets of each tier, finest first, and the last tier.
tiers :: U.Vector Int -> ([U.Vector Int], U.Vector Int)
tiers s
  | U.length s <= 2 = ([], s)
  | otherwise = let (d, next) = split s; (ds, final) = tiers next in (d : ds, final)

chunks :: U.Vector Int -> [U.Vector Int]
chunks d = [U.slice s (min chunkSize (U.length d - s)) d | s <- [0, chunkSize .. U.length d - 1]]

encodeChunk :: U.Vector Int -> S.Vector Word8
encodeChunk d = runST $ do
  buf <- SM.new (64 + 11 * U.length d)
  w <- putBitLength buf start d
  bytes <- finish buf w
  S.force . S.take bytes <$> S.unsafeFreeze buf

word64 :: Int -> S.Vector Word8
word64 x = S.fromList [fromIntegral (x `unsafeShiftR` s) | s <- [56, 48 .. 0]]

readWord64 :: S.Vector Word8 -> Int -> Int
readWord64 v o = foldl (\a i -> (a `unsafeShiftL` 8) .|. fromIntegral (S.unsafeIndex v (o + i))) 0 [0 .. 7]

-- | The header of Blocks, the last tier of each channel in 64-bit words, a 32-bit byte length for every chunk
-- (by channel, coarsest tier first), then the chunks.
encodeTiers :: Int -> Bool -> [U.Vector Int] -> S.Vector Word8
encodeTiers depth float chans = S.concat (header : finals ++ map (word32 . S.length) payloads ++ payloads)
  where
    n = case chans of
      (c : _) -> U.length c
      [] -> 0
    split' = map tiers chans
    payloads = parMapNF encodeChunk [c | (ds, _) <- split', d <- reverse ds, c <- chunks d]
    finals = [word64 x | (_, f) <- split', x <- U.toList f]
    header = S.concat [word32 n, S.fromList [fromIntegral (length chans), fromIntegral depth, if float then 1 else 0]]

decodeTiers :: S.Vector Word8 -> [U.Vector Int]
decodeTiers v = parMapNF channel [0 .. nch - 1]
  where
    n = readWord32 v 0
    nch = fromIntegral (S.unsafeIndex v 4)
    finalLength = last (lengths n)
    coarseFirst = reverse (init (lengths n))
    counts = [(l `quot` 2 + chunkSize - 1) `quot` chunkSize | l <- coarseFirst]
    perChannel = sum counts
    indexAt = 7 + 8 * finalLength * nch
    sizes = U.generate (nch * perChannel) (\i -> readWord32 v (indexAt + 4 * i))
    starts = U.prescanl (+) (indexAt + 4 * nch * perChannel) sizes
    chunk i m = fst (getBitLength (S.slice (U.unsafeIndex starts i) (U.unsafeIndex sizes i) v) 0 m)
    channel c = foldl step final (zip3 coarseFirst counts (scanl (+) (c * perChannel) counts))
      where
        final = U.generate finalLength (\i -> readWord64 v (7 + 8 * (c * finalLength + i)))
        step next (len, count, first) =
          let m k = min chunkSize (len `quot` 2 - k * chunkSize)
          in join len next (U.concat (parMapNF (\k -> chunk (first + k) (m k)) [0 .. count - 1]))
