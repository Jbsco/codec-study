-- | Fixed polynomial prediction in independent blocks of 4096 samples. Each block starts from its own first
-- samples, so blocks encode and decode in parallel, and a byte length per block locates it in the stream.
module Blocks (Coder (..), encodeBlocks, decodeBlocks, word32, readWord32) where

import Control.Monad (foldM, forM_)
import Control.Monad.ST (runST)
import Data.Bits
import qualified Data.Vector.Storable as S
import qualified Data.Vector.Storable.Mutable as SM
import qualified Data.Vector.Unboxed as U
import qualified Data.Vector.Unboxed.Mutable as UM
import Data.Word (Word8)

import Bits
import Coding
import Parallel

-- | Rice codes, bit-length Huffman codes, or whichever is shorter for each block, marked by one bit.
data Coder = Rice | BitLength | Shorter
  deriving (Eq, Show)

blockSize :: Int
blockSize = 4096

predict :: Int -> (Int -> Int) -> Int
predict order s = case order of
  0 -> 0
  1 -> s 1
  2 -> 2 * s 1 - s 2
  3 -> 3 * s 1 - 3 * s 2 + s 3
  _ -> 4 * s 1 - 6 * s 2 + 4 * s 3 - s 4
{-# INLINE predict #-}

residuals :: Int -> U.Vector Int -> U.Vector Int
residuals order x = U.generate (U.length x - order) at
  where
    at j = let i = j + order in U.unsafeIndex x i - predict order (\k -> U.unsafeIndex x (i - k))

-- | The order with the least absolute residual; the sums fuse with the residuals and allocate nothing.
bestOrder :: U.Vector Int -> Int
bestOrder x = snd (minimum [(U.foldl' (\s r -> s + abs r) 0 (residuals o x), o) | o <- [0 .. min 4 (U.length x - 1)]])

-- | The order in 3 bits, the first Order samples in Depth bits, a coder bit when Flag is set, then the residuals.
encodeWith :: Bool -> Coder -> Int -> U.Vector Int -> S.Vector Word8
encodeWith flag coder depth x = runST $ do
  buf <- SM.new (64 + 11 * U.length x)
  let order = bestOrder x
  w1 <- put buf start (fromIntegral order) 3
  w2 <- foldM (\w i -> putLong buf w (fromIntegral (U.unsafeIndex x i)) depth) w1 [0 .. order - 1]
  w3 <- if flag then put buf w2 (if coder == Rice then 0 else 1) 1 else pure w2
  w4 <- (if coder == Rice then putRice else putBitLength) buf w3 (residuals order x)
  bytes <- finish buf w4
  S.force . S.take bytes <$> S.unsafeFreeze buf

encodeBlock :: Coder -> Int -> U.Vector Int -> S.Vector Word8
encodeBlock Shorter depth x
  | S.length r <= S.length b = r
  | otherwise = b
  where
    r = encodeWith True Rice depth x
    b = encodeWith True BitLength depth x
encodeBlock coder depth x = encodeWith False coder depth x

decodeBlock :: Coder -> Int -> Int -> S.Vector Word8 -> U.Vector Int
decodeBlock coder depth n v = integrate order warm r
  where
    order = fromIntegral (getBits v 0 3)
    warm = U.generate order (\i -> signExtend (fromIntegral (getLong v (3 + depth * i) depth)))
    p0 = 3 + depth * order
    (rice, p1) = case coder of
      Rice -> (True, p0)
      BitLength -> (False, p0)
      Shorter -> (getBits v p0 1 == 0, p0 + 1)
    r = fst ((if rice then getRice else getBitLength) v p1 (n - order))
    signExtend s = if s >= bit (depth - 1) then s - bit depth else s

integrate :: Int -> U.Vector Int -> U.Vector Int -> U.Vector Int
integrate order warm r = U.create $ do
  let n = order + U.length r
  x <- UM.new n
  forM_ [0 .. order - 1] $ \i -> UM.unsafeWrite x i (U.unsafeIndex warm i)
  let back i k = if k <= order then UM.unsafeRead x (i - k) else pure 0
      go i
        | i == n = pure ()
        | otherwise = do
            s1 <- back i 1
            s2 <- back i 2
            s3 <- back i 3
            s4 <- back i 4
            let s k = case k of
                  1 -> s1
                  2 -> s2
                  3 -> s3
                  _ -> s4
            UM.unsafeWrite x i (U.unsafeIndex r (i - order) + predict order s)
            go (i + 1)
  go order
  pure x

-- | Frames in 32 bits, then channels, depth and a float flag in 8 bits each, a 32-bit byte length for every
-- block of every channel, then the blocks.
encodeBlocks :: Coder -> Int -> Bool -> [U.Vector Int] -> S.Vector Word8
encodeBlocks coder depth float chans = S.concat (header : map (word32 . S.length) blocks ++ blocks)
  where
    n = case chans of
      (c : _) -> U.length c
      [] -> 0
    blocks = parMapNF (encodeBlock coder depth) [U.slice s (min blockSize (n - s)) c | c <- chans, s <- [0, blockSize .. n - 1]]
    header = S.concat [word32 n, S.fromList [fromIntegral (length chans), fromIntegral depth, if float then 1 else 0]]

decodeBlocks :: Coder -> S.Vector Word8 -> [U.Vector Int]
decodeBlocks coder v = [U.concat (take count (drop (c * count) decoded)) | c <- [0 .. nch - 1]]
  where
    n = readWord32 v 0
    nch = fromIntegral (S.unsafeIndex v 4)
    depth = fromIntegral (S.unsafeIndex v 5)
    sizes = [min blockSize (n - s) | s <- [0, blockSize .. n - 1]]
    count = length sizes
    lens = [readWord32 v (7 + 4 * i) | i <- [0 .. nch * count - 1]]
    offsets = scanl (+) (7 + 4 * nch * count) lens
    decoded = parMapNF (\(o, l, m) -> decodeBlock coder depth m (S.slice o l v)) (zip3 offsets lens (concat (replicate nch sizes)))

word32 :: Int -> S.Vector Word8
word32 x = S.fromList [fromIntegral (x `unsafeShiftR` s) | s <- [24, 16, 8, 0]]

readWord32 :: S.Vector Word8 -> Int -> Int
readWord32 v o = foldl (\a i -> (a `unsafeShiftL` 8) .|. fromIntegral (S.unsafeIndex v (o + i))) 0 [0 .. 3]
