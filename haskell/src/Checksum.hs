-- | CRC-16 over any bytes, polynomial 0x1021 most significant bit first, initial value 0xFFFF, no reflection and
-- no final exclusive or (CRC-16/CCITT-FALSE), one table lookup per byte; the same function as ada/checksums.ads.
module Checksum (crc16) where

import Data.Bits
import qualified Data.Vector.Storable as S
import qualified Data.Vector.Unboxed as U
import Data.Word (Word16, Word8)

table :: U.Vector Word16
table = U.generate 256 (\b -> iterate step (fromIntegral b `shiftL` 8) !! 8)
  where
    step r = if testBit r 15 then (r `shiftL` 1) `xor` 0x1021 else r `shiftL` 1

crc16 :: S.Vector Word8 -> Word16
crc16 = S.foldl' (\r b -> (r `shiftL` 8) `xor` U.unsafeIndex table (fromIntegral ((r `shiftR` 8) `xor` fromIntegral b))) 0xFFFF
