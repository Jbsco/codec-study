-- | IEEE bit patterns between 64-bit and 32-bit float, as ada/float_bits.ads defines them. narrow gives the 32-bit
-- pattern when the 64-bit value is exactly a 32-bit one; widen is exact for every 32-bit value.
module FloatBits (narrow, widen) where

import Data.Bits (complement, countLeadingZeros, shiftL, shiftR, (.&.), (.|.))
import Data.Word (Word32, Word64)

narrow :: Word64 -> Maybe Word32
narrow d
  | e == 0x7FF = if m .&. low29 == 0 && (m == 0 || m `shiftR` 29 /= 0) then Just (sign .|. 0x7F800000 .|. fromIntegral (m `shiftR` 29)) else Nothing
  | e == 0 = if m == 0 then Just sign else Nothing
  | u >= -126 && u <= 127 = if m .&. low29 == 0 then Just (sign .|. fromIntegral (u + 127) `shiftL` 23 .|. fromIntegral (m `shiftR` 29)) else Nothing
  | u >= -149 && u <= -127 =
      let full = m .|. (1 `shiftL` 52)
          s = -97 - u
      in if full .&. ((1 `shiftL` s) - 1) == 0 then Just (sign .|. fromIntegral (full `shiftR` s)) else Nothing
  | otherwise = Nothing
  where
    sign = fromIntegral (d `shiftR` 63) `shiftL` 31 :: Word32
    e = fromIntegral (d `shiftR` 52) .&. 0x7FF :: Int
    m = d .&. ((1 `shiftL` 52) - 1)
    u = e - 1023
    low29 = (1 `shiftL` 29) - 1

widen :: Word32 -> Word64
widen s
  | e == 0xFF = sign .|. (0x7FF `shiftL` 52) .|. (f `shiftL` 29)
  | e == 0 && f == 0 = sign
  | e == 0 =
      let top = 63 - countLeadingZeros f
      in sign .|. (fromIntegral (top - 149 + 1023) `shiftL` 52) .|. ((f `shiftL` (52 - top)) .&. complement (complement 0 `shiftL` 52))
  | otherwise = sign .|. (fromIntegral (e - 127 + 1023) `shiftL` 52) .|. (f `shiftL` 29)
  where
    sign = fromIntegral (s `shiftR` 31) `shiftL` 63 :: Word64
    e = fromIntegral (s `shiftR` 23) .&. 0xFF :: Int
    f = fromIntegral (s .&. 0x7FFFFF) :: Word64
