{-# LANGUAGE BangPatterns #-}
-- | Bit packing and unpacking, most significant bit first.
module Bits (W (..), Buffer, start, put, putLong, putZeros, finish, peek32, getBits, getLong) where

import Control.Monad.ST (ST)
import Data.Bits
import qualified Data.Vector.Storable as S
import qualified Data.Vector.Storable.Mutable as SM
import Data.Word (Word64, Word8)

type Buffer s = SM.MVector s Word8

-- | Writer state: the next byte to write, the pending bits, and how many are pending.
data W = W {-# UNPACK #-} !Int {-# UNPACK #-} !Word64 {-# UNPACK #-} !Int

start :: W
start = W 0 0 0

-- | Write the low K bits of V, K at most 32.
put :: Buffer s -> W -> Word64 -> Int -> ST s W
put buf (W p acc n) v k = flush p ((acc `unsafeShiftL` k) .|. (v .&. ((1 `unsafeShiftL` k) - 1))) (n + k)
  where
    flush !q !a !m
      | m < 8 = pure (W q a m)
      | otherwise = SM.unsafeWrite buf q (fromIntegral (a `unsafeShiftR` (m - 8))) >> flush (q + 1) a (m - 8)
{-# INLINE put #-}

-- | Write the low K bits of V, K at most 64.
putLong :: Buffer s -> W -> Word64 -> Int -> ST s W
putLong buf w v k
  | k <= 32 = put buf w v k
  | otherwise = put buf w (v `unsafeShiftR` 32) (k - 32) >>= \w' -> put buf w' v 32
{-# INLINE putLong #-}

-- | Write Q zero bits.
putZeros :: Buffer s -> W -> Int -> ST s W
putZeros buf w q
  | q <= 32 = put buf w 0 q
  | otherwise = put buf w 0 32 >>= \w' -> putZeros buf w' (q - 32)

-- | Pad the last byte with zeros and return the number of bytes written.
finish :: Buffer s -> W -> ST s Int
finish buf (W p acc n)
  | n == 0 = pure p
  | otherwise = SM.unsafeWrite buf p (fromIntegral (acc `unsafeShiftL` (8 - n))) >> pure (p + 1)

-- | The 32 bits from bit P, zero past the end.
peek32 :: S.Vector Word8 -> Int -> Word64
peek32 v p = (w `unsafeShiftR` (8 - (p .&. 7))) .&. 0xFFFFFFFF
  where
    i = p `unsafeShiftR` 3
    b k = if i + k < S.length v then fromIntegral (S.unsafeIndex v (i + k)) else 0
    w = (b 0 `unsafeShiftL` 32) .|. (b 1 `unsafeShiftL` 24) .|. (b 2 `unsafeShiftL` 16) .|. (b 3 `unsafeShiftL` 8) .|. b 4
{-# INLINE peek32 #-}

-- | K bits from bit P, K at most 32.
getBits :: S.Vector Word8 -> Int -> Int -> Word64
getBits v p k = peek32 v p `unsafeShiftR` (32 - k)
{-# INLINE getBits #-}

-- | K bits from bit P, K at most 64.
getLong :: S.Vector Word8 -> Int -> Int -> Word64
getLong v p k
  | k <= 32 = getBits v p k
  | otherwise = (getBits v p (k - 32) `unsafeShiftL` 32) .|. getBits v (p + k - 32) 32
{-# INLINE getLong #-}
