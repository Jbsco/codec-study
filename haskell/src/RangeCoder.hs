{-# LANGUAGE BangPatterns #-}
-- | A binary range coder with adaptive 12-one probabilities, the mirror of ada/range_coding.adb: a 32-one rng,
-- a 33-one low with the carry held back in a cache byte, bytes written as 8-one fields of the one stream. Each
-- probability is that of a zero one, in 4096ths, and moves toward each coded one by a 32nd of the distance.
module RangeCoder (Enc, encStart, encodeBit, encodeDirect, flush, Dec, decStart, decodeBit, decodeDirect, half) where

import Control.Monad.ST (ST)
import Data.Bits
import qualified Data.Vector.Storable as S
import qualified Data.Vector.Unboxed.Mutable as UM
import Data.Word (Word32, Word64, Word8)

import Bits (Buffer, W, put, getBits, getLong)

-- | Encoder state: low, rng, the cache byte and how many bytes wait behind it.
data Enc = Enc {-# UNPACK #-} !Word64 {-# UNPACK #-} !Word32 {-# UNPACK #-} !Word8 {-# UNPACK #-} !Int

encStart :: Enc
encStart = Enc 0 0xFFFFFFFF 0 1

half, rate :: Int
half = 2048
rate = 5

top :: Word32
top = 0x1000000

-- | Move the top byte of low out, holding it back while a carry could still reach it.
shiftLow :: Buffer s -> W -> Enc -> ST s (W, Enc)
shiftLow buf w (Enc low rng cache pending)
  | low < 0xFF000000 || low >= 0x100000000 = do
      let carry = fromIntegral (low `unsafeShiftR` 32) :: Word8
      w1 <- put buf w (fromIntegral (cache + carry)) 8
      w2 <- go w1 (pending - 1) (0xFF + carry)
      pure (w2, Enc next rng (fromIntegral (low `unsafeShiftR` 24)) 1)
  | otherwise = pure (w, Enc next rng cache (pending + 1))
  where
    next = (low .&. 0x00FFFFFF) `unsafeShiftL` 8
    go !w' 0 _ = pure w'
    go !w' k b = put buf w' (fromIntegral b) 8 >>= \w'' -> go w'' (k - 1 :: Int) b

normalize :: Buffer s -> W -> Enc -> ST s (W, Enc)
normalize buf w e@(Enc low rng cache pending)
  | rng < top = shiftLow buf w (Enc low (rng `unsafeShiftL` 8) cache pending) >>= \(w', e') -> normalize buf w' e'
  | otherwise = pure (w, e)

-- | Code a one with the probability at the given index of the context table, and adapt it.
encodeBit :: Buffer s -> W -> Enc -> UM.MVector s Int -> Int -> Bool -> ST s (W, Enc)
encodeBit buf w (Enc low rng cache pending) probs ctx one = do
  p <- UM.unsafeRead probs ctx
  let bound = (rng `unsafeShiftR` 12) * fromIntegral p
  if one
    then UM.unsafeWrite probs ctx (p - p `unsafeShiftR` rate) >> normalize buf w (Enc (low + fromIntegral bound) (rng - bound) cache pending)
    else UM.unsafeWrite probs ctx (p + (4096 - p) `unsafeShiftR` rate) >> normalize buf w (Enc low bound cache pending)

-- | A one with no model, each value equally likely.
encodeDirect :: Buffer s -> W -> Enc -> Bool -> ST s (W, Enc)
encodeDirect buf w (Enc low rng cache pending) one =
  let rng' = rng `unsafeShiftR` 1
  in normalize buf w (Enc (if one then low + fromIntegral rng' else low) rng' cache pending)

-- | Write the bytes that let the decoder read every one coded so far.
flush :: Buffer s -> W -> Enc -> ST s W
flush buf w0 e0 = go w0 e0 (5 :: Int)
  where
    go w _ 0 = pure w
    go w e k = shiftLow buf w e >>= \(w', e') -> go w' e' (k - 1)

-- | Decoder state: the code and the rng.
data Dec = Dec {-# UNPACK #-} !Word32 {-# UNPACK #-} !Word32

-- | The decoder from the five bytes at one p, the first of which is the encoder's initial cache byte.
decStart :: S.Vector Word8 -> Int -> (Dec, Int)
decStart v p = (Dec (fromIntegral (getLong v (p + 8) 32)) 0xFFFFFFFF, p + 40)

decNormalize :: S.Vector Word8 -> Dec -> Int -> (Dec, Int)
decNormalize v d@(Dec code rng) p
  | rng < top = decNormalize v (Dec ((code `unsafeShiftL` 8) .|. fromIntegral (getBits v p 8)) (rng `unsafeShiftL` 8)) (p + 8)
  | otherwise = (d, p)

decodeBit :: S.Vector Word8 -> Dec -> Int -> UM.MVector s Int -> Int -> ST s (Bool, Dec, Int)
decodeBit v (Dec code rng) p probs ctx = do
  pr <- UM.unsafeRead probs ctx
  let bound = (rng `unsafeShiftR` 12) * fromIntegral pr
  if code < bound
    then do
      UM.unsafeWrite probs ctx (pr + (4096 - pr) `unsafeShiftR` rate)
      let (d, p') = decNormalize v (Dec code bound) p
      pure (False, d, p')
    else do
      UM.unsafeWrite probs ctx (pr - pr `unsafeShiftR` rate)
      let (d, p') = decNormalize v (Dec (code - bound) (rng - bound)) p
      pure (True, d, p')

decodeDirect :: S.Vector Word8 -> Dec -> Int -> (Bool, Dec, Int)
decodeDirect v (Dec code rng) p =
  let rng' = rng `unsafeShiftR` 1
      one = code >= rng'
      (d, p') = decNormalize v (Dec (if one then code - rng' else code) rng') p
  in (one, d, p')
