{-# LANGUAGE BangPatterns #-}

-- | MD5 (RFC 1321) of a strict byte string, for the stream header's digest of the input samples.
module Md5 (md5) where

import Data.Bits
import qualified Data.ByteString as B
import qualified Data.ByteString.Unsafe as BU
import qualified Data.Vector.Unboxed as U
import Data.Word (Word32, Word8)

md5 :: B.ByteString -> [Word8]
md5 msg = concatMap littleEndian [a, b, c, d]
  where
    len = B.length msg
    full = len - len `rem` 64
    padding = B.concat [B.drop full msg, B.singleton 0x80, B.replicate ((55 - len) `mod` 64) 0,
                        B.pack [fromIntegral ((8 * len) `shiftR` (8 * k)) | k <- [0 .. 7]]]
    start = (0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476)
    (a, b, c, d) = blocks padding 0 (blocks msg 0 start full) (B.length padding)

    blocks bs !off st end
      | off >= end = st
      | otherwise = blocks bs (off + 64) (block bs off st) end

    block bs off (a0, b0, c0, d0) = rounds 0 a0 b0 c0 d0
      where
        word i = let o = off + 4 * i
                     byte k = fromIntegral (BU.unsafeIndex bs (o + k)) :: Word32
                 in byte 0 .|. byte 1 `shiftL` 8 .|. byte 2 `shiftL` 16 .|. byte 3 `shiftL` 24
        rounds :: Int -> Word32 -> Word32 -> Word32 -> Word32 -> (Word32, Word32, Word32, Word32)
        rounds !i !x !y !z !w
          | i == 64 = (a0 + x, b0 + y, c0 + z, d0 + w)
          | otherwise =
              let (f, g)
                    | i < 16 = ((y .&. z) .|. (complement y .&. w), i)
                    | i < 32 = ((w .&. y) .|. (complement w .&. z), (5 * i + 1) .&. 15)
                    | i < 48 = (y `xor` z `xor` w, (3 * i + 5) .&. 15)
                    | otherwise = (z `xor` (y .|. complement w), (7 * i) .&. 15)
                  f' = f + x + U.unsafeIndex constants i + word g
              in rounds (i + 1) w (y + f' `rotateL` U.unsafeIndex amounts i) y z

    littleEndian v = [fromIntegral (v `shiftR` (8 * k)) | k <- [0 .. 3]]

amounts :: U.Vector Int
amounts = U.fromList (concatMap (concat . replicate 4) [[7, 12, 17, 22], [5, 9, 14, 20], [4, 11, 16, 23], [6, 10, 15, 21]])

constants :: U.Vector Word32
constants = U.fromList
  [ 0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501
  , 0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be, 0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821
  , 0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa, 0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8
  , 0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed, 0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a
  , 0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c, 0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70
  , 0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665
  , 0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1
  , 0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1, 0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391
  ]
