-- | The Ada and SPARK block coder of ada/lib/libblockcodec.so through its C entry points, wrapped as pure
-- functions. Each call codes one block and shares no state, so calls from many capabilities run at once.
module SparkFFI (sparkEncode, sparkDecode) where

import Data.Int (Int64)
import qualified Data.Vector.Storable as S
import qualified Data.Vector.Storable.Mutable as SM
import qualified Data.Vector.Unboxed as U
import Data.Word (Word8)
import Foreign.C.Types (CInt (..))
import Foreign.Ptr (Ptr)
import System.IO.Unsafe (unsafePerformIO)

foreign import ccall unsafe "block_encode"
  c_encode :: Ptr Int64 -> CInt -> CInt -> Ptr Word8 -> CInt -> IO CInt

foreign import ccall unsafe "block_decode"
  c_decode :: Ptr Word8 -> CInt -> CInt -> CInt -> Ptr Int64 -> IO CInt

sparkEncode :: Int -> U.Vector Int -> S.Vector Word8
sparkEncode depth x = unsafePerformIO $ do
  let n = U.length x
      capacity = 5 * n + 16
      samples = S.convert (U.map fromIntegral x :: U.Vector Int64)
  out <- SM.new capacity
  bytes <- S.unsafeWith samples $ \px -> SM.unsafeWith out $ \po ->
    c_encode px (fromIntegral n) (fromIntegral depth) po (fromIntegral capacity)
  if bytes < 0
    then error "block_encode: arguments out of range"
    else S.force . S.take (fromIntegral bytes) <$> S.unsafeFreeze out
{-# NOINLINE sparkEncode #-}

sparkDecode :: Int -> Int -> S.Vector Word8 -> U.Vector Int
sparkDecode depth n v = unsafePerformIO $ do
  out <- SM.new n
  status <- S.unsafeWith v $ \pv -> SM.unsafeWith out $ \po ->
    c_decode pv (fromIntegral (S.length v)) (fromIntegral n) (fromIntegral depth) po
  if status /= 0
    then error ("block_decode: status " ++ show status)
    else U.map fromIntegral . (U.convert :: S.Vector Int64 -> U.Vector Int64) <$> S.unsafeFreeze out
{-# NOINLINE sparkDecode #-}
