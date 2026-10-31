-- | The block codec of ada/block_codec.adb written again in Haskell, byte for byte the same format. A block
-- holds a constant, or the residuals of one predictor after the low bits every sample shares are removed:
-- polynomial orders 0 to 4, the distance back to an exact repeat, or tiers of pairs. The residuals take Rice
-- codes or run-length Huffman codes, and the encoder writes whichever combination is shortest.
module BlockCodec (maxBlock, bound, encodeBlock, decodeBlock) where

import Control.Monad (forM_, when)
import Control.Monad.ST (ST, runST)
import Data.Bits
import Data.List (sortOn)
import qualified Data.Vector.Storable as S
import qualified Data.Vector.Storable.Mutable as SM
import qualified Data.Vector.Unboxed as U
import qualified Data.Vector.Unboxed.Mutable as UM
import Data.Word (Word32, Word64, Word8)

import Bits

maxBlock :: Int
maxBlock = 4096

-- | The most bytes a block of N samples takes.
bound :: Int -> Int
bound n = 5 * n + 16

delayPredictor, tierPredictor, sixteenZeros, matchLength, symbolCount :: Int
delayPredictor = 5
tierPredictor = 6
sixteenZeros = 15 * 64
matchLength = 32
symbolCount = 1024

zigzag :: Int -> Word64
zigzag x = fromIntegral ((x `unsafeShiftL` 1) `xor` (x `unsafeShiftR` 63))

unzigzag :: Word64 -> Int
unzigzag u = fromIntegral (u `unsafeShiftR` 1) `xor` negate (fromIntegral (u .&. 1))

bitLength :: Word64 -> Int
bitLength u = 64 - countLeadingZeros u

magnitude :: Int -> Word64
magnitude x = fromIntegral (abs x)

fixedPrediction :: (Int -> Int) -> Int -> Int
fixedPrediction s k = case k of
  0 -> 0
  1 -> s 1
  2 -> 2 * s 1 - s 2
  3 -> 3 * s 1 - 3 * s 2 + s 3
  _ -> 4 * s 1 - 6 * s 2 + 4 * s 3 - s 4
{-# INLINE fixedPrediction #-}

residuals :: Int -> Int -> U.Vector Int -> U.Vector Int
residuals predictor delay y
  | predictor <= 4 = U.generate n (\i -> at i - fixedPrediction (\j -> at (i - j)) (min predictor i))
  | predictor == delayPredictor = U.generate n (\i -> if i == 0 then at 0 else at i - at (if i >= delay then i - delay else i - 1))
  | otherwise = tierResiduals y
  where
    n = U.length y
    at = U.unsafeIndex y

-- | The final tier, then the offsets of each tier from the coarsest to the finest.
tierResiduals :: U.Vector Int -> U.Vector Int
tierResiduals = go []
  where
    go acc s
      | U.length s <= 2 = U.concat (s : acc)
      | otherwise = let (d, next) = split s in go (d : acc) next
    split s = (U.generate g offset, U.generate g anchor U.++ U.drop (2 * g) s)
      where
        g = U.length s `quot` 2
        anchor j = U.unsafeIndex s (2 * j)
        following j = if j < g - 1 then anchor (j + 1) else anchor j
        offset j = U.unsafeIndex s (2 * j + 1) - (anchor j + following j) `quot` 2

-- | The smallest distance at which the first 32 samples repeat exactly, or zero.
findDelay :: U.Vector Int -> Int
findDelay y = case [p | p <- [1 .. U.length y - matchLength], all (\j -> U.unsafeIndex y (p + j) == U.unsafeIndex y j) [0 .. matchLength - 1]] of
  (p : _) -> p
  [] -> 0

-- | The Rice parameter of least cost, the smallest of equals, walked from the bit length of the mean code value.
riceCost :: U.Vector Int -> (Int, Word64)
riceCost r
  | k0 > 0, c1 <= c0 = down (k0 - 1) c1
  | otherwise = up k0 c0
  where
    n = fromIntegral (U.length r) :: Word64
    cost p = n * fromIntegral (p + 1) + U.foldl' (\a v -> a + zigzag v `unsafeShiftR` p) 0 r
    k0 = max (bitLength (U.foldl' (\a v -> a + zigzag v) 0 r `quot` n)) 1 - 1
    c0 = cost k0
    c1 = cost (k0 - 1)
    down k c
      | k > 0, c' <= c = down (k - 1) c'
      | otherwise = (k, c)
      where
        c' = cost (k - 1)
    up k c
      | k < 62, c' < c = up (k + 1) c'
      | otherwise = (k, c)
      where
        c' = cost (k + 1)

-- | Counts of each run-length symbol, and the bits of the values' signs and lower bits.
runSymbols :: U.Vector Int -> (U.Vector Int, Word64)
runSymbols r = runST $ do
  counts <- UM.replicate symbolCount 0
  let bump = UM.unsafeModify counts (+ 1)
      sixteens k
        | k >= 16 = bump sixteenZeros >> sixteens (k - 16)
        | otherwise = pure k
      step (run, bits) v
        | v == 0 = pure (run + 1, bits)
        | otherwise = do
            run' <- sixteens run
            let b = bitLength (magnitude v)
            bump (run' * 64 + b)
            pure (0 :: Int, bits + fromIntegral b)
  (run, bits) <- U.foldM' step (0, 0) r
  when (run > 0) (bump 0)
  c <- U.unsafeFreeze counts
  pure (c, bits)

-- | Huffman code lengths: leaves sorted by count then symbol, two queues, a leaf before a node of equal weight.
codeLengths :: U.Vector Int -> U.Vector Int
codeLengths counts = U.create $ do
  lens <- UM.replicate (U.length counts) 0
  let leaves = sortOn fst [(c, s) | (s, c) <- zip [0 ..] (U.toList counts), c > 0]
      m = length leaves
      weights = U.fromList (map fst leaves)
      symbols = U.fromList (map snd leaves) :: U.Vector Int
  case m of
    0 -> pure ()
    1 -> UM.write lens (U.head symbols) 1
    _ -> do
      nodeWeight <- UM.replicate (m - 1) 0
      leafParent <- UM.replicate m 0
      nodeParent <- UM.replicate (m - 1) 0
      depth <- UM.replicate (m - 1) (0 :: Int)
      let take1 k (nl, nn) = do
            useLeaf <-
              if nl >= m then pure False
              else if nn == k then pure True
              else (U.unsafeIndex weights nl <=) <$> UM.read nodeWeight nn
            if useLeaf
              then UM.write leafParent nl k >> UM.modify nodeWeight (+ U.unsafeIndex weights nl) k >> pure (nl + 1, nn)
              else do
                UM.write nodeParent nn k
                w <- UM.read nodeWeight nn
                UM.modify nodeWeight (+ w) k
                pure (nl, nn + 1)
          merge k q
            | k > m - 2 = pure ()
            | otherwise = take1 k q >>= take1 k >>= merge (k + 1)
      merge 0 (0, 0)
      forM_ [m - 3, m - 4 .. 0] $ \j -> UM.read nodeParent j >>= UM.read depth >>= UM.write depth j . (+ 1)
      forM_ [0 .. m - 1] $ \i -> UM.read leafParent i >>= UM.read depth >>= UM.write lens (U.unsafeIndex symbols i) . (+ 1)
  pure lens

-- | Canonical codes in symbol order, as in RFC 1951 section 3.2.2.
canonical :: U.Vector Int -> U.Vector Word64
canonical lens = U.create $ do
  codes <- UM.replicate (U.length lens) 0
  next <- U.thaw (U.fromList (0 : starts))
  forM_ [0 .. U.length lens - 1] $ \s -> do
    let l = U.unsafeIndex lens s
    when (l > 0) $ do
      c <- UM.read next l
      UM.write codes s c
      UM.write next l (c + 1)
  pure codes
  where
    count l = if l == 0 then 0 else U.length (U.filter (== l) lens)
    starts = tail (scanl (\c b -> (c + fromIntegral (count (b - 1))) `shiftL` 1) 0 [1 .. 31 :: Int])

gammaLength :: Int -> Word64
gammaLength k = fromIntegral (2 * bitLength (fromIntegral k) - 1)

usedSymbols :: U.Vector Int -> [Int]
usedSymbols counts = [s | s <- [0 .. symbolCount - 1], U.unsafeIndex counts s > 0]

runCost :: U.Vector Int -> Word64
runCost r = 11 + valueBits + sum [gammaLength (s - prev) + 5 + fromIntegral (U.unsafeIndex counts s * U.unsafeIndex lens s) | (s, prev) <- zip used ((-1) : used)]
  where
    (counts, valueBits) = runSymbols r
    lens = codeLengths counts
    used = usedSymbols counts

putGamma :: Buffer s -> W -> Int -> ST s W
putGamma buf w k = do
  let b = bitLength (fromIntegral k)
  w' <- putZeros buf w (b - 1)
  putLong buf w' (fromIntegral k) b

putRice :: Buffer s -> W -> Int -> U.Vector Int -> ST s W
putRice buf w0 k r = do
  w1 <- put buf w0 (fromIntegral k) 6
  U.foldM' (\w v -> do
              let u = zigzag v
              w' <- putZeros buf w (fromIntegral (u `unsafeShiftR` k))
              w'' <- put buf w' 1 1
              putLong buf w'' u k) w1 r

putRun :: Buffer s -> W -> U.Vector Int -> ST s W
putRun buf w0 r = do
  w1 <- put buf w0 (fromIntegral (length used)) 11
  w2 <- foldl (\mw (s, prev) -> mw >>= \w -> putGamma buf w (s - prev) >>= \w' -> put buf w' (fromIntegral (U.unsafeIndex lens s)) 5)
          (pure w1) (zip used ((-1) : used))
  let code s w = put buf w (U.unsafeIndex codes s) (U.unsafeIndex lens s)
      sixteens k w
        | k >= 16 = code sixteenZeros w >>= sixteens (k - 16)
        | otherwise = pure w
      step (run, w) v
        | v == 0 = pure (run + 1, w)
        | otherwise = do
            let b = bitLength (magnitude v)
            w' <- sixteens run w >>= code ((run `rem` 16) * 64 + b)
            w'' <- put buf w' (if v < 0 then 1 else 0) 1
            w''' <- putLong buf w'' (magnitude v) (b - 1)
            pure (0 :: Int, w''')
  (run, w3) <- U.foldM' step (0, w2) r
  if run > 0 then code 0 w3 else pure w3
  where
    (counts, _) = runSymbols r
    lens = codeLengths counts
    codes = canonical lens
    used = usedSymbols counts

encodeBlock :: Int -> U.Vector Int -> S.Vector Word8
encodeBlock depth x = runST $ do
  buf <- SM.new (bound (U.length x))
  w <- if U.all (== U.head x) x
    then put buf start 0 1 >>= \w1 -> putLong buf w1 (fromIntegral (U.head x)) depth
    else do
      w1 <- put buf start 1 1
      w2 <- put buf w1 (fromIntegral lowZeros) 5
      w3 <- put buf w2 (fromIntegral bestPredictor) 3
      w4 <- if bestPredictor == delayPredictor then put buf w3 (fromIntegral delay) 12 else pure w3
      w5 <- put buf w4 (if bestRice then 0 else 1) 1
      let r = residuals bestPredictor delay y
      if bestRice then putRice buf w5 bestK r else putRun buf w5 r
  bytes <- finish buf w
  S.force . S.take bytes <$> S.unsafeFreeze buf
  where
    common = U.foldl' (\a v -> a .|. (fromIntegral v :: Word64)) 0 x
    lowZeros = countTrailingZeros common
    y = U.map (`unsafeShiftR` lowZeros) x
    delay = findDelay y
    candidates =
      [ (bits, p, rice, k)
      | p <- [0 .. tierPredictor], p /= delayPredictor || delay > 0
      , let r = residuals p delay y
            header = if p == delayPredictor then 22 else 10
            (k, riceBits) = riceCost r
      , (bits, rice) <- [(header + 6 + riceBits, True), (header + runCost r, False)]
      ]
    (_, bestPredictor, bestRice, bestK) = foldl1 (\a b -> if first4 b < first4 a then b else a) candidates
    first4 (b, _, _, _) = b

---------------------------------------------------------------------------------------------------------------
-- Decoder

getRiceR :: S.Vector Word8 -> Int -> Int -> (U.Vector Int, Int)
getRiceR v p0 n = runST $ do
  out <- UM.new n
  let k = fromIntegral (getBits v p0 6)
      unary q p =
        let z = countLeadingZeros (fromIntegral (peek32 v p) :: Word32)
        in if z == 32 then unary (q + 32) (p + 32) else (q + z, p + z + 1)
      go i p
        | i == n = pure p
        | otherwise = do
            let (q, p') = unary 0 p
            UM.unsafeWrite out i (unzigzag ((fromIntegral q `unsafeShiftL` k) .|. getLong v p' k))
            go (i + 1) (p' + k)
  p <- go 0 (p0 + 6)
  xs <- U.unsafeFreeze out
  pure (xs, p)

-- | Read gamma codes and lengths, then decode symbols through each length's first code.
getRunR :: S.Vector Word8 -> Int -> Int -> (U.Vector Int, Int)
getRunR v p0 n = runST $ do
  out <- UM.replicate n 0
  let entries = readEntries (fromIntegral (getBits v p0 11) :: Int) (p0 + 11) (-1) []
      (table, p1) = case entries of (es, p) -> (es, p)
      sorted = sortOn (\(s, l) -> (l, s)) table
      longest = maximum (map snd sorted)
      counts = U.accumulate (+) (U.replicate 32 0) (U.fromList [(l, 1 :: Int) | (_, l) <- sorted])
      firsts = U.fromList (0 : tail (scanl (\c b -> (c + fromIntegral (if b == 1 then 0 else U.unsafeIndex counts (b - 1))) `shiftL` 1) (0 :: Word64) [1 .. 31 :: Int]))
      offsets = U.prescanl (+) 0 counts
      symbols = U.fromList (map fst sorted)
      decodeSym w = go 1
        where
          go l
            | l > longest = error "invalid run-length code"
            | code >= f && code - f < fromIntegral (U.unsafeIndex counts l) =
                (U.unsafeIndex symbols (U.unsafeIndex offsets l + fromIntegral (code - f)), l)
            | otherwise = go (l + 1)
            where
              code = w `unsafeShiftR` (32 - l)
              f = U.unsafeIndex firsts l
      loop i p
        | i >= n = pure p
        | otherwise = do
            let (s, l) = decodeSym (peek32 v p)
                q = p + l
            if s == 0 then pure q
            else if s == sixteenZeros then loop (i + 16) q
            else do
              let b = s .&. 63
                  j = i + s `shiftR` 6
                  m = fromIntegral ((1 `unsafeShiftL` (b - 1)) .|. getLong v (q + 1) (b - 1)) :: Int
              UM.unsafeWrite out j (if getBits v q 1 == 1 then negate m else m)
              loop (j + 1) (q + b)
  p <- loop 0 p1
  xs <- U.unsafeFreeze out
  pure (xs, p)
  where
    readEntries :: Int -> Int -> Int -> [(Int, Int)] -> ([(Int, Int)], Int)
    readEntries 0 p _ acc = (reverse acc, p)
    readEntries k p prev acc =
      let z = countLeadingZeros (fromIntegral (peek32 v p) :: Word32)
          stepSize = fromIntegral (getLong v (p + z) (z + 1)) :: Int
          s = prev + stepSize
          l = fromIntegral (getBits v (p + 2 * z + 1) 5)
      in readEntries (k - 1) (p + 2 * z + 6) s ((s, l) : acc)

rebuild :: Int -> Int -> U.Vector Int -> U.Vector Int
rebuild predictor delay r
  | predictor == tierPredictor = untier r
  | otherwise = U.create $ do
      y <- UM.new n
      forM_ [0 .. n - 1] $ \i -> do
        p <- if predictor == delayPredictor
          then if i == 0 then pure 0 else UM.unsafeRead y (if i >= delay then i - delay else i - 1)
          else do
            let k = min predictor i
            s1 <- if k >= 1 then UM.unsafeRead y (i - 1) else pure 0
            s2 <- if k >= 2 then UM.unsafeRead y (i - 2) else pure 0
            s3 <- if k >= 3 then UM.unsafeRead y (i - 3) else pure 0
            s4 <- if k >= 4 then UM.unsafeRead y (i - 4) else pure 0
            pure (fixedPrediction (\j -> case j of { 1 -> s1; 2 -> s2; 3 -> s3; _ -> s4 }) k)
        UM.unsafeWrite y i (U.unsafeIndex r i + p)
      pure y
  where
    n = U.length r

untier :: U.Vector Int -> U.Vector Int
untier r = go (U.take (last lens) r) (U.length r - sum gs) (reverse (init lens))
  where
    lens = takeWhile' (U.length r)
    takeWhile' l = l : if l <= 2 then [] else takeWhile' (l `quot` 2 + l `rem` 2)
    gs = [l `quot` 2 | l <- init lens]
    go cur _ [] = cur
    go cur ptr (l : ls) = go (join l cur (U.slice ptr g r)) (ptr + g) ls
      where
        g = l `quot` 2
    join len next d = U.generate len value
      where
        g = len `quot` 2
        anchor j = U.unsafeIndex next j
        following j = if j < g - 1 then anchor (j + 1) else anchor j
        value i
          | i >= 2 * g = U.unsafeIndex next (i - g)
          | even i = anchor (i `quot` 2)
          | otherwise = let j = i `quot` 2 in U.unsafeIndex d j + (anchor j + following j) `quot` 2

decodeBlock :: Int -> Int -> S.Vector Word8 -> U.Vector Int
decodeBlock depth n v
  | getBits v 0 1 == 0 =
      let u = fromIntegral (getLong v 1 depth) :: Int
      in U.replicate n (if u >= bit (depth - 1) then u - bit depth else u)
  | otherwise = U.map (`unsafeShiftL` lowZeros) (rebuild predictor delay r)
  where
    lowZeros = fromIntegral (getBits v 1 5)
    predictor = fromIntegral (getBits v 6 3)
    (delay, p0) = if predictor == delayPredictor then (fromIntegral (getBits v 9 12), 21) else (0, 9)
    r = fst ((if getBits v p0 1 == 0 then getRiceR else getRunR) v (p0 + 1) n)
