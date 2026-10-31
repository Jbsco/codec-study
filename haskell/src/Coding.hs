{-# LANGUAGE BangPatterns #-}
-- | Coders for blocks of residuals: Rice codes, and canonical Huffman codes of each residual's bit length
-- followed by its sign and the bits below its leading one.
module Coding (putRice, getRice, putBitLength, getBitLength) where

import Control.Monad (foldM)
import Control.Monad.ST (ST, runST)
import Data.Bits
import Data.List (insertBy, mapAccumL, sortOn)
import qualified Data.Map.Strict as M
import Data.Ord (comparing)
import qualified Data.Vector.Storable as S
import qualified Data.Vector.Unboxed as U
import qualified Data.Vector.Unboxed.Mutable as UM
import Data.Word (Word32, Word64, Word8)

import Bits

zigzag :: Int -> Word64
zigzag x = fromIntegral ((x `unsafeShiftL` 1) `xor` (x `unsafeShiftR` 63))
{-# INLINE zigzag #-}

unzigzag :: Word64 -> Int
unzigzag u = fromIntegral (u `unsafeShiftR` 1) `xor` negate (fromIntegral (u .&. 1))
{-# INLINE unzigzag #-}

riceCost :: U.Vector Int -> Int -> Int
riceCost xs k = U.length xs * (k + 1) + U.foldl' (\s x -> s + fromIntegral (zigzag x `unsafeShiftR` k)) 0 xs

-- | Start from the logarithm of the mean and step while the cost falls.
riceParameter :: U.Vector Int -> Int
riceParameter xs = walk k0 (riceCost xs k0)
  where
    mean = U.foldl' (\s x -> s + fromIntegral (zigzag x)) 0 xs `div` U.length xs :: Int
    k0 = max 0 (63 - countLeadingZeros mean)
    walk k c
      | k > 0, c' <- riceCost xs (k - 1), c' < c = down (k - 1) c'
      | otherwise = up k c
    down k c
      | k > 0, c' <- riceCost xs (k - 1), c' < c = down (k - 1) c'
      | otherwise = k
    up k c
      | k < 62, c' <- riceCost xs (k + 1), c' < c = up (k + 1) c'
      | otherwise = k

-- | A 6-bit parameter K, then per residual its zigzag value shifted right by K in unary and its low K bits.
putRice :: Buffer s -> W -> U.Vector Int -> ST s W
putRice buf w0 xs
  | U.null xs = pure w0
  | otherwise = do
      let k = riceParameter xs
      w1 <- put buf w0 (fromIntegral k) 6
      U.foldM' (\w x -> do
                  let u = zigzag x
                  w' <- putZeros buf w (fromIntegral (u `unsafeShiftR` k))
                  w'' <- put buf w' 1 1
                  putLong buf w'' u k) w1 xs

getRice :: S.Vector Word8 -> Int -> Int -> (U.Vector Int, Int)
getRice v p0 n
  | n == 0 = (U.empty, p0)
  | otherwise = runST $ do
      out <- UM.new n
      let k = fromIntegral (getBits v p0 6)
          unary !q !p =
            let z = countLeadingZeros (fromIntegral (peek32 v p) :: Word32)
            in if z == 32 then unary (q + 32) (p + 32) else (q + z, p + z + 1)
          go !i !p
            | i == n = pure p
            | otherwise = do
                let (q, p') = unary 0 p
                UM.unsafeWrite out i (unzigzag ((fromIntegral q `unsafeShiftL` k) .|. getLong v p' k))
                go (i + 1) (p' + k)
      p <- go 0 (p0 + 6)
      xs <- U.unsafeFreeze out
      pure (xs, p)

bitLength :: Int -> Int
bitLength x = 64 - countLeadingZeros (fromIntegral (abs x) :: Word64)
{-# INLINE bitLength #-}

-- | Huffman code lengths for symbols with counts above zero.
codeLengths :: [(Int, Int)] -> [(Int, Int)]
codeLengths [(s, _)] = [(s, 1)]
codeLengths sc = merge (sortOn fst [(c, [(s, 0)]) | (s, c) <- sc])
  where
    merge ((w1, a) : (w2, b) : rest) = merge (insertBy (comparing fst) (w1 + w2, [(s, d + 1) | (s, d) <- a ++ b]) rest)
    merge [(_, ls)] = ls
    merge [] = []

-- | The first code of each length 1 to the longest, as in RFC 1951 section 3.2.2.
firstCodes :: [Int] -> [Word64]
firstCodes lens = tail (scanl step 0 [1 .. maximum (0 : lens)])
  where
    step c b = (c + fromIntegral (count (b - 1))) `shiftL` 1
    count 0 = 0
    count l = length (filter (== l) lens)

-- | Canonical codes in symbol order for lengths by symbol, zero for unused.
canonical :: [Int] -> [Word64]
canonical lens = snd (mapAccumL assign (M.fromList (zip [1 ..] (firstCodes lens))) lens)
  where
    assign m 0 = (m, 0)
    assign m l = (M.adjust (+ 1) l m, m M.! l)

-- | Per code length: the first code, the number of codes and the index of the first symbol.
data Table = Table !Int !(U.Vector Word64) !(U.Vector Int) !(U.Vector Int) !(U.Vector Int)

table :: [Int] -> Table
table lens = Table longest (U.fromList (0 : firstCodes lens)) (U.fromList (0 : counts)) (U.fromList (0 : offsets)) symbols
  where
    longest = maximum (0 : lens)
    counts = [length (filter (== l) lens) | l <- [1 .. longest]]
    offsets = init (scanl (+) 0 counts)
    symbols = U.fromList [s | l <- [1 .. longest], (s, l') <- zip [0 ..] lens, l' == l]

-- | The symbol and code length at the front of 32 peeked bits.
decodeSymbol :: Table -> Word64 -> (Int, Int)
decodeSymbol (Table longest firsts counts offsets symbols) w = go 1
  where
    go !l
      | l > longest = error "invalid Huffman code"
      | code >= f && code - f < fromIntegral (U.unsafeIndex counts l) =
          (U.unsafeIndex symbols (U.unsafeIndex offsets l + fromIntegral (code - f)), l)
      | otherwise = go (l + 1)
      where
        code = w `unsafeShiftR` (32 - l)
        f = U.unsafeIndex firsts l
{-# INLINE decodeSymbol #-}

-- | The largest bit length used, L, in 6 bits and the code lengths of bit lengths 0 to L in 5 bits each,
-- then per residual the code of its bit length B and, when B is above zero, a sign bit and B - 1 bits.
putBitLength :: Buffer s -> W -> U.Vector Int -> ST s W
putBitLength buf w0 xs
  | U.null xs = pure w0
  | otherwise = do
      let lens = M.elems (M.union (M.fromList (codeLengths used)) (M.fromList [(s, 0) | s <- [0 .. lastLength]]))
          codes = U.fromList (canonical lens)
          lv = U.fromList lens
      w1 <- put buf w0 (fromIntegral lastLength) 6
      w2 <- foldM (\w l -> put buf w (fromIntegral l) 5) w1 lens
      U.foldM' (\w x -> do
                  let b = bitLength x
                  w' <- put buf w (U.unsafeIndex codes b) (U.unsafeIndex lv b)
                  if b == 0
                    then pure w'
                    else do
                      w'' <- put buf w' (if x < 0 then 1 else 0) 1
                      putLong buf w'' (fromIntegral (abs x)) (b - 1)) w2 xs
  where
    hist = U.accumulate (+) (U.replicate 64 0) (U.map (\x -> (bitLength x, 1 :: Int)) xs)
    lastLength = U.maximum (U.map bitLength xs)
    used = [(s, c) | (s, c) <- zip [0 .. lastLength] (U.toList hist), c > 0]

getBitLength :: S.Vector Word8 -> Int -> Int -> (U.Vector Int, Int)
getBitLength v p0 n
  | n == 0 = (U.empty, p0)
  | otherwise = runST $ do
      let lastLength = fromIntegral (getBits v p0 6)
          t = table [fromIntegral (getBits v (p0 + 6 + 5 * i) 5) | i <- [0 .. lastLength]]
      out <- UM.new n
      let go !i !p
            | i == n = pure p
            | otherwise = do
                let (b, l) = decodeSymbol t (peek32 v p)
                    p1 = p + l
                if b == 0
                  then UM.unsafeWrite out i 0 >> go (i + 1) p1
                  else do
                    let m = fromIntegral ((1 `unsafeShiftL` (b - 1)) .|. getLong v (p1 + 1) (b - 1)) :: Int
                    UM.unsafeWrite out i (if getBits v p1 1 == 1 then negate m else m)
                    go (i + 1) (p1 + b)
      p <- go 0 (p0 + 6 + 5 * (lastLength + 1))
      xs <- U.unsafeFreeze out
      pure (xs, p)
