-- | The block codec of ada/block_codec.adb written again in Haskell, byte for byte the same format. A block
-- holds a constant, or the residuals of one predictor after the low bits every sample shares are removed:
-- polynomial orders 0 to 4, the distance back to an exact repeat within the block or in the samples before it,
-- tiers of pairs, or linear prediction of order 1 to 32 with quantized coefficients. The residuals take Rice
-- codes or run-length Huffman codes, and the encoder writes whichever combination is shortest.
module BlockCodec (Effort (..), maxBlock, maxHistory, bound, log2', encodeBlock, decodeBlock, usesHistory) where

import Control.Monad (foldM, forM_, when)
import Control.Monad.ST (ST, runST)
import Data.Bits
import Data.List (foldl', sortOn)
import qualified Data.Vector.Storable as S
import qualified Data.Vector.Storable.Mutable as SM
import qualified Data.Vector.Unboxed as U
import qualified Data.Vector.Unboxed.Mutable as UM
import Data.Word (Word32, Word64, Word8)

import Bits

maxBlock, maxHistory :: Int
maxBlock = 4096
maxHistory = 16384

-- | The most bytes a block of N samples takes.
bound :: Int -> Int
bound n = 5 * n + 16

delayPredictor, tierPredictor, lpcPredictor, maxOrder, rampOrder, sixteenZeros, matchLength, symbolCount :: Int
delayPredictor = 5
tierPredictor = 6
lpcPredictor = 7
maxOrder = 32
rampOrder = 2

-- | The encoder's number for the delay that reaches before the block; the format writes it as the delay
-- predictor with its history flag set.
backDelay :: Int
backDelay = 8

lmsShift, lmsStep, lmsWeightLimit, lmsResidualLimit, maxWarmUp, stageSaving :: Int
stageSaving = 64
lmsShift = 14
lmsStep = 2
lmsWeightLimit = 32768
lmsResidualLimit = 137438953472
maxWarmUp = 4096

tapChoices, warmUpChoices :: [Int]
tapChoices = [16, 32, 64, 256]
warmUpChoices = [0, 256, 1024, 4096]

clampResidual :: Int -> Int
clampResidual = max (negate lmsResidualLimit) . min lmsResidualLimit

-- | The sign-sign LMS stage of ada/block_codec.adb over a residual sequence: each output is the input less the
-- weighted sum of the last taps inputs shifted down, after which every weight moves by the step toward the sign
-- of the output times the sign of its input. The first split outputs train the stage and are dropped.
lmsPass :: Int -> Int -> U.Vector Int -> U.Vector Int
lmsPass taps split r = U.create $ do
  out <- UM.new (U.length r - split)
  w <- UM.replicate taps 0
  h <- UM.replicate taps 0
  let signOf v = if v > 0 then 1 else if v < 0 then -1 else 0 :: Int
      predictOf = foldM (\a j -> (\x y -> a + x * y) <$> UM.unsafeRead w j <*> UM.unsafeRead h j) 0 [0 .. taps - 1]
  forM_ [0 .. U.length r - 1] $ \i -> do
    p <- predictOf
    let e = U.unsafeIndex r i - p `shiftR` lmsShift
        se = signOf (clampResidual e)
    when (i >= split) (UM.unsafeWrite out (i - split) e)
    when (se /= 0) $ forM_ [0 .. taps - 1] $ \j -> do
      hj <- UM.unsafeRead h j
      UM.unsafeModify w (\v -> max (negate lmsWeightLimit) (min lmsWeightLimit (v + lmsStep * se * signOf hj))) j
    forM_ [taps - 1, taps - 2 .. 1] $ \j -> UM.unsafeRead h (j - 1) >>= UM.unsafeWrite h j
    UM.unsafeWrite h 0 (clampResidual (U.unsafeIndex r i))
  pure out

-- | LPC residuals of z from position from on, each predicted from the samples before it in z.
seededResiduals :: U.Vector Int -> U.Vector Int -> Int -> Int -> U.Vector Int
seededResiduals z q qshift from = U.generate (U.length z - from) (\k -> U.unsafeIndex z (k + from) - U.sum (U.zipWith (*) reversedQ (U.unsafeSlice (k + from - order) order z)) `shiftR` qshift)
  where
    order = U.length q
    reversedQ = U.reverse q
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

-- | The smallest distance, at most the length of the history, at which the first 32 samples repeat the samples
-- that far before them, counting back into the history, or zero.
findBack :: U.Vector Int -> U.Vector Int -> Int
findBack history x
  | U.length x < matchLength = 0
  | otherwise = case [p | p <- [1 .. lh], all (\j -> before (j - p) == U.unsafeIndex x j) [0 .. matchLength - 1]] of
      (p : _) -> p
      [] -> 0
  where
    lh = U.length history
    before k = if k >= 0 then U.unsafeIndex x k else U.unsafeIndex history (lh + k)

-- | Residuals from the sample the given distance before each one, history samples scaled down by the shift.
backResiduals :: Int -> Int -> U.Vector Int -> U.Vector Int -> U.Vector Int
backResiduals back zeros history y = U.imap (\i v -> v - reference i) y
  where
    reference i
      | i >= back = U.unsafeIndex y (i - back)
      | otherwise = U.unsafeIndex history (U.length history + i - back) `shiftR` zeros

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

-- | How far the encoder searches: how many orders of linear prediction it codes in full, ranked by the bits their
-- prediction error implies (0 for none, 32 for all), and the lowest coefficient precision it tries. Every setting
-- writes the same format.
data Effort = Effort { effortOrders :: !Int, effortPrecisionFrom :: !Int, effortAdaptive :: !Bool }

-- | The base-2 logarithm of a positive X within 3e-6: its exponent, and a polynomial in its fraction.
log2' :: Double -> Double
log2' x = fromIntegral (exponent x - 1)
  + t * (1.4425347795670296 + t * (-0.7180335903817996 + t * (0.45715812106557047 + t * (-0.2773416459579797
  + t * (0.12147294837882355 + t * (-0.025792345031509872))))))
  where
    t = 2 * significand x - 1

-- | Predictor coefficients for each order up to maxOrder with the prediction error after it, from the
-- Levinson-Durbin recursion on the autocorrelation of the block under a window whose first and last quarters rise
-- as a smoothstep.
lpcAnalysis :: U.Vector Int -> [(U.Vector Double, Double)]
lpcAnalysis y
  | not (U.head ac > 0) = []
  | otherwise = go 1 (U.singleton 1) (U.head ac)
  where
    n = U.length y
    m = max 1 (n `quot` 4)
    top = min maxOrder (n - 1)
    tapered = U.imap (\i v -> let t = min 1 (fromIntegral (min (i + 1) (n - i)) / fromIntegral (m + 1)) :: Double
                              in fromIntegral v * (t * t * (3 - 2 * t))) y
    ac = U.generate (top + 1) (\k -> U.foldl' (+) 0 (U.zipWith (*) (U.take (n - k) tapered) (U.drop k tapered)))
    go p a err
      | p > top = []
      | otherwise = (U.map negate (U.tail a'), err') : if err' > 0 then go (p + 1) a' err' else []
      where
        acc = foldl' (\s j -> s + U.unsafeIndex a j * U.unsafeIndex ac (p - j)) (U.unsafeIndex ac p) [1 .. p - 1]
        k = negate acc / err
        a' = U.generate (p + 1) (\j -> if j == 0 then 1 else if j == p then k else U.unsafeIndex a j + k * U.unsafeIndex a (p - j))
        err' = err * (1 - k * k)

-- | The coefficients of one order as integers of the given precision over 2^shift, each rounded with the error
-- of the ones before it carried forward.
quantize :: U.Vector Double -> Int -> Maybe (U.Vector Int, Int)
quantize c precision
  | U.any (\v -> not (abs v < 1.0e300)) c || not (peak > 0) || precision - 1 - exponent peak < 0 = Nothing
  | otherwise = Just (U.fromList (go 0 (U.toList c)), qshift)
  where
    peak = U.foldl' (\a v -> max a (abs v)) 0 c
    qshift = min (precision - 1 - exponent peak) 31
    limit = bit (precision - 1) :: Int
    scale = 2 ^ qshift :: Double
    go :: Double -> [Double] -> [Int]
    go _ [] = []
    go carry (v : vs) = q : go (carry' - fromIntegral q) vs
      where
        carry' = carry + v * scale
        q = max (negate limit) (min (limit - 1) (floor (carry' + 0.5)))

-- | The ramp of the first samples, and the prediction residuals of the rest; Nothing when a residual needs more
-- than width + 4 bits.
lpcResiduals :: U.Vector Int -> U.Vector Int -> Int -> Int -> Maybe (U.Vector Int, U.Vector Int)
lpcResiduals y q qshift width
  | U.any (\v -> v <= negate limit || v >= limit) r = Nothing
  | otherwise = Just (warm, r)
  where
    order = U.length q
    limit = bit (width + 3) :: Int
    at = U.unsafeIndex y
    warm = U.generate order (\i -> at i - fixedPrediction (\j -> at (i - j)) (min rampOrder i))
    reversedQ = U.reverse q
    r = U.generate (U.length y - order) (\k -> at (k + order) - U.sum (U.zipWith (*) reversedQ (U.unsafeSlice k order y)) `shiftR` qshift)

-- | An LPC coding: order, coefficient precision and shift, the residual code and its parameters, and the values.
data Lpc = Lpc
  { lOrder, lPrecision, lShift, lK, lWarmK :: !Int
  , lRice :: !Bool
  , lQ, lWarm, lR :: !(U.Vector Int)
  , lTapCode, lWarmCode :: !Int
  , lLms :: !Bool
  }

-- | The shortest LPC coding: the order with the least Rice cost at 15-bit precision, then the precision and the
-- residual code with the least cost at that order.
bestLpc :: Effort -> Int -> Int -> U.Vector Int -> U.Vector Int -> Maybe (Word64, Lpc)
bestLpc effort lowBits width history y
  | null stage1 || null stage2 = Nothing
  | otherwise = Just (foldl pickStage (foldl1 (\a b -> if fst b < fst a then b else a) stage2) stage3)
  where
    -- The stage is kept only where it saves at least one bit per stageSaving samples, since the decoder pays its
    -- taps on every sample of a block that carries it; among stage candidates the comparison is plain.
    margin = fromIntegral (U.length y `quot` stageSaving) :: Word64
    pickStage (bestBits, best) (bits, cand) = if bits + margin < bestBits + (if lLms best then margin else 0) then (bits, cand) else (bestBits, best)
    chosen0 = snd (foldl1 (\a b -> if fst b < fst a then b else a) stage2)
    available = min (U.length history) (maxWarmUp + lOrder chosen0)
    z = U.map (`shiftR` lowBits) (U.drop (U.length history - available) history) U.++ y
    seeded = seededResiduals z (lQ chosen0) (lShift chosen0) (lOrder chosen0)
    limit = bit (width + 3) :: Int
    stage3 =
      [ (bits, chosen0 { lK = ke, lWarmK = 0, lRice = rice, lR = e, lTapCode = tapCode, lWarmCode = warmCode, lLms = True })
      | effortAdaptive effort, U.length history >= lOrder chosen0
      , (warmCode, warmUp) <- zip [0 ..] warmUpChoices, warmUp <= available - lOrder chosen0
      , (tapCode, taps) <- zip [0 ..] tapChoices
      , let e = lmsPass taps warmUp (U.drop (U.length seeded - n - warmUp) seeded)
      , U.all (\v -> v > negate limit && v < limit) e
      , let (ke, ce) = riceCost e
            front = 24 + fromIntegral (lPrecision chosen0 * lOrder chosen0) + 1 + 4
      , (bits, rice) <- [(front + 6 + ce, True), (front + runCost e, False)]
      ]
    analysis = lpcAnalysis y
    sets = map fst analysis
    n = U.length y
    estimate p e = if e > 0 then 0.5 * fromIntegral (n - p) * log2' e + 15 * fromIntegral p else -1.0e300
    estimates = U.fromList [estimate p e | (p, (_, e)) <- zip [1 :: Int ..] analysis]
    pick chosen = foldl (\best p -> if p `elem` chosen || (best /= 0 && estimates U.! (p - 1) >= estimates U.! (best - 1)) then best else p)
                        0 [1 .. length sets]
    chosenOrders
      | effortOrders effort >= length sets = [1 .. length sets]
      | otherwise = sortOn id (iterate (\c -> pick c : c) [] !! effortOrders effort)
    stage1 =
      [ (24 + 15 * fromIntegral order + 1 + 6 + snd (riceCost warm) + 6 + snd (riceCost r), order)
      | (order, c) <- zip [1 ..] sets, order `elem` chosenOrders
      , Just (q, s) <- [quantize c 15]
      , Just (warm, r) <- [lpcResiduals y q s width]
      ]
    bestOrder = snd (foldl1 (\a b -> if fst b < fst a then b else a) stage1) :: Int
    stage2 =
      [ (bits, Lpc bestOrder precision s k kw rice q warm r 0 0 False)
      | precision <- [effortPrecisionFrom effort .. 15]
      , Just (q, s) <- [quantize (sets !! (bestOrder - 1)) precision]
      , Just (warm, r) <- [lpcResiduals y q s width]
      , let (kw, cw) = riceCost warm
            (k, cr) = riceCost r
            front = 24 + fromIntegral (precision * bestOrder) + 1 + 6 + cw
      , (bits, rice) <- [(front + 6 + cr, True), (front + runCost r, False)]
      ]

putLpc :: Buffer s -> W -> Lpc -> ST s W
putLpc buf w0 l = do
  w1 <- put buf w0 (fromIntegral lpcPredictor) 3
  w2 <- put buf w1 (fromIntegral (lOrder l - 1)) 5
  w3 <- put buf w2 (fromIntegral (lPrecision l - 1)) 4
  w4 <- put buf w3 (fromIntegral (lShift l)) 5
  w5 <- U.foldM' (\w c -> put buf w (fromIntegral c) (lPrecision l)) w4 (lQ l)
  w6 <- if lLms l
    then put buf w5 1 1 >>= \a -> put buf a (fromIntegral (lTapCode l)) 2 >>= \b -> put buf b (fromIntegral (lWarmCode l)) 2
    else put buf w5 0 1 >>= \a -> putRice buf a (lWarmK l) (lWarm l)
  w7 <- put buf w6 (if lRice l then 0 else 1) 1
  if lRice l then putRice buf w7 (lK l) (lR l) else putRun buf w7 (lR l)

-- | Code one block, given the samples just before it, the latest last.
encodeBlock :: Effort -> Int -> U.Vector Int -> U.Vector Int -> S.Vector Word8
encodeBlock effort depth history x = runST $ do
  buf <- SM.new (bound (U.length x))
  w <- if U.all (== U.head x) x
    then put buf start 0 1 >>= \w1 -> putLong buf w1 (fromIntegral (U.head x)) depth
    else do
      w1 <- put buf start 1 1
      w2 <- put buf w1 (fromIntegral lowZeros) 5
      case lpc of
        Just (lpcBits, l) | lpcBits < bestBits -> putLpc buf w2 l
        _ -> do
          w3 <- put buf w2 (fromIntegral (if bestPredictor == backDelay then delayPredictor else bestPredictor)) 3
          w4 <- if bestPredictor == delayPredictor then put buf w3 0 1 >>= \w' -> put buf w' (fromIntegral delay) 12
                else if bestPredictor == backDelay then put buf w3 1 1 >>= \w' -> put buf w' (fromIntegral back) 15
                else pure w3
          w5 <- put buf w4 (if bestRice then 0 else 1) 1
          let r = candidateResiduals bestPredictor
          if bestRice then putRice buf w5 bestK r else putRun buf w5 r
  bytes <- finish buf w
  S.force . S.take bytes <$> S.unsafeFreeze buf
  where
    lpc = if effortOrders effort > 0 then bestLpc effort lowZeros (depth - lowZeros) history y else Nothing
    common = U.foldl' (\a v -> a .|. (fromIntegral v :: Word64)) 0 x
    lowZeros = countTrailingZeros common
    y = U.map (`unsafeShiftR` lowZeros) x
    delay = findDelay y
    back = findBack history x
    candidateResiduals p = if p == backDelay then backResiduals back lowZeros history y else residuals p delay y
    candidates =
      [ (bits, p, rice, k)
      | p <- [0 .. tierPredictor] ++ [backDelay | back > 0], p /= delayPredictor || delay > 0
      , let r = candidateResiduals p
            header = if p == delayPredictor then 23 else if p == backDelay then 26 else 10
            (k, riceBits) = riceCost r
      , (bits, rice) <- [(header + 6 + riceBits, True), (header + runCost r, False)]
      ]
    (bestBits, bestPredictor, bestRice, bestK) = foldl1 (\a b -> if first4 b < first4 a then b else a) candidates
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

-- | Samples from residuals; for a delay that reaches before the block, Before gives the scaled sample at a
-- negative position.
rebuild :: Int -> Int -> Maybe (Int -> Int) -> U.Vector Int -> U.Vector Int
rebuild predictor delay before r
  | predictor == tierPredictor = untier r
  | otherwise = U.create $ do
      y <- UM.new n
      forM_ [0 .. n - 1] $ \i -> do
        p <- if predictor == delayPredictor
          then if i >= delay then UM.unsafeRead y (i - delay)
               else case before of
                 Just h -> pure (h (i - delay))
                 Nothing -> if i == 0 then pure 0 else UM.unsafeRead y (i - 1)
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

-- | An LPC block from its order field at bit P0: the coefficients, the ramp of the first samples, then the rest.
-- | An LPC block from its order field at bit p0, given the scaled samples before the block for its adaptive stage.
decodeLpc :: U.Vector Int -> S.Vector Word8 -> Int -> Int -> U.Vector Int
decodeLpc before v p0 n
  | lms = U.drop (U.length seededAll - n) rebuilt
  | otherwise = U.create $ do
      y <- UM.new n
      forM_ [0 .. order - 1] $ \i -> do
        s1 <- if i >= 1 then UM.unsafeRead y (i - 1) else pure 0
        s2 <- if i >= 2 then UM.unsafeRead y (i - 2) else pure 0
        UM.unsafeWrite y i (U.unsafeIndex warm i + fixedPrediction (\j -> if j == 1 then s1 else s2) (min rampOrder i))
      forM_ [order .. n - 1] $ \i -> do
        s <- foldM (\a j -> (\u -> a + U.unsafeIndex q (j - 1) * u) <$> UM.unsafeRead y (i - j)) 0 [1 .. order]
        UM.unsafeWrite y i (U.unsafeIndex r (i - order) + s `shiftR` qshift)
      pure y
  where
    order = fromIntegral (getBits v p0 5) + 1
    precision = fromIntegral (getBits v (p0 + 5) 4) + 1
    qshift = fromIntegral (getBits v (p0 + 9) 5)
    q = U.generate order (\j -> signed (fromIntegral (getBits v (p0 + 14 + j * precision) precision)))
    signed u = if u >= bit (precision - 1) then u - bit precision else u
    flagAt = p0 + 14 + order * precision
    lms = getBits v flagAt 1 == 1
    taps = tapChoices !! fromIntegral (getBits v (flagAt + 1) 2)
    warmUp = warmUpChoices !! fromIntegral (getBits v (flagAt + 3) 2)
    (warm, pc) = if lms then (U.empty, flagAt + 5) else getRiceR v (flagAt + 1) order
    first = if lms then 0 else order
    r = fst ((if getBits v pc 1 == 0 then getRiceR else getRunR) v (pc + 1) (n - first))
    -- With the stage: the LPC residuals of the warm-up samples train it, then each block residual is the coded
    -- error plus the stage's prediction, and the sample is that residual plus the LPC prediction.
    used = U.drop (U.length before - warmUp - order) before
    seededAll = U.create $ do
      z <- UM.new (U.length used + n)
      forM_ [0 .. U.length used - 1] $ \i -> UM.unsafeWrite z i (U.unsafeIndex used i)
      w <- UM.replicate taps 0
      h <- UM.replicate taps 0
      let signOf x = if x > 0 then 1 else if x < 0 then -1 else 0 :: Int
          predictOf = foldM (\a j -> (\x yv -> a + x * yv) <$> UM.unsafeRead w j <*> UM.unsafeRead h j) 0 [0 .. taps - 1]
          lpcOf i = foldM (\a j -> (\u -> a + U.unsafeIndex q (j - 1) * u) <$> UM.unsafeRead z (i - j)) 0 [1 .. order]
          update e res = do
            let se = signOf (clampResidual e)
            when (se /= 0) $ forM_ [0 .. taps - 1] $ \j -> do
              hj <- UM.unsafeRead h j
              UM.unsafeModify w (\x -> max (negate lmsWeightLimit) (min lmsWeightLimit (x + lmsStep * se * signOf hj))) j
            forM_ [taps - 1, taps - 2 .. 1] $ \j -> UM.unsafeRead h (j - 1) >>= UM.unsafeWrite h j
            UM.unsafeWrite h 0 (clampResidual res)
      forM_ [order .. U.length used - 1] $ \i -> do
        s <- lpcOf i
        zi <- UM.unsafeRead z i
        let res = zi - s `shiftR` qshift
        p <- predictOf
        update (res - p `shiftR` lmsShift) res
      forM_ [U.length used .. U.length used + n - 1] $ \i -> do
        s <- lpcOf i
        p <- predictOf
        let e = U.unsafeIndex r (i - U.length used)
            res = e + p `shiftR` lmsShift
        UM.unsafeWrite z i (res + s `shiftR` qshift)
        update e res
      pure z
    rebuilt = seededAll

-- | Whether a coded block repeats samples from before it, and so needs them to decode.
usesHistory :: S.Vector Word8 -> Bool
usesHistory v = getBits v 0 1 == 1 && (delayed || adaptive)
  where
    predictor = getBits v 6 3
    delayed = predictor == fromIntegral delayPredictor && getBits v 9 1 == 1
    order = fromIntegral (getBits v 9 5) + 1 :: Int
    precision = fromIntegral (getBits v 14 4) + 1 :: Int
    adaptive = predictor == fromIntegral lpcPredictor && getBits v (23 + order * precision) 1 == 1

-- | Decode N samples of one block, given the decoded samples just before it, the latest last.
decodeBlock :: Int -> U.Vector Int -> Int -> S.Vector Word8 -> U.Vector Int
decodeBlock depth history n v
  | getBits v 0 1 == 0 =
      let u = fromIntegral (getLong v 1 depth) :: Int
      in U.replicate n (if u >= bit (depth - 1) then u - bit depth else u)
  | predictor == lpcPredictor = U.map (`unsafeShiftL` lowZeros) (decodeLpc (U.map (`shiftR` lowZeros) history) v 9 n)
  | otherwise = U.map (`unsafeShiftL` lowZeros) (rebuild predictor delay before r)
  where
    lowZeros = fromIntegral (getBits v 1 5)
    predictor = fromIntegral (getBits v 6 3)
    fromHistory = predictor == delayPredictor && getBits v 9 1 == 1
    (delay, p0)
      | predictor /= delayPredictor = (0, 9)
      | fromHistory = (fromIntegral (getBits v 10 15), 25)
      | otherwise = (fromIntegral (getBits v 10 12), 22)
    before
      | fromHistory = Just (\k -> U.unsafeIndex history (U.length history + k) `shiftR` lowZeros)
      | otherwise = Nothing
    r = fst ((if getBits v p0 1 == 0 then getRiceR else getRunR) v (p0 + 1) n)
