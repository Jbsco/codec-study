-- | The stream of the block codec, as ada/codec_main.adb writes it: frames in 32 bits; channels, depth and a
-- float flag in 8 bits each; for float input a mode and a scale per channel; for two channels a 2-bit stereo mode
-- per group of 4096 frames; a 32-bit byte length for every block; then the blocks, group by group. A pair of
-- channels in the same float mode codes each group as left and right, left and side, side and right, or mid and
-- side, whichever is shortest. Groups encode in parallel with any block coder of the same format. Blocks that
-- need no samples from before them decode in parallel; then the groups decode the rest in order.
module Stream (Prepared (..), prepare, encodeStream, decodeStream) where

import Data.Bits
import qualified Data.Vector as V
import qualified Data.Vector.Storable as S
import qualified Data.Vector.Unboxed as U
import Data.Maybe (fromMaybe)
import Data.Word (Word8)

import BlockCodec (maxBlock, maxHistory, usesHistory)
import Bits (getBits)
import Blocks (readWord32, word32)
import Parallel
import Wav

-- | Channels as the codec sees them: integers, float samples as integers over a power of two (mode 1), or
-- float bit patterns in the order-keeping map (mode 2).
data Prepared = Prepared
  { pFrames :: !Int
  , pDepth :: !Int
  , pFloat :: !Bool
  , pModes :: [(Int, Int)]
  , pCoded :: [U.Vector Int]
  }

prepare :: Audio -> Prepared
prepare a
  | isFloat a =
      let found = map toIntegers (channels a)
      in Prepared (frames a) (depth a) True [maybe (2, 0) (\(s, _) -> (1, s)) f | f <- found]
           [maybe c snd f | (f, c) <- zip found (channels a)]
  | otherwise = Prepared (frames a) (depth a) False [] (channels a)

-- | Integers I with sample = I / 2**S for every sample, when one S up to 31 fits them all.
toIntegers :: U.Vector Int -> Maybe (Int, U.Vector Int)
toIntegers xs = do
  fractions <- mapM (fraction . bitsOf) (U.toList xs)
  let s = maximum (0 : fractions)
  if s > 31 then Nothing else (,) s <$> U.mapM (scaled s . bitsOf) xs
  where
    bitsOf v = if v >= 0 then v else 2147483647 - v
    fields b = ((b `shiftR` 23) .&. 255, b .&. 8388607)
    fraction b
      | b == 2147483648 || e == 255 || (e == 0 && m /= 0) = Nothing
      | b .&. 2147483647 == 0 = Just 0
      | otherwise = Just (150 - e - countTrailingZeros (8388608 + m))
      where
        (e, m) = fields b
    scaled s b
      | b .&. 2147483647 == 0 = Just 0
      | up > 7 || mag >= 2147483648 = Nothing
      | otherwise = Just (if b >= 2147483648 then negate mag else mag)
      where
        (e, m) = fields b
        up = e - 150 + s
        mag = if up >= 0 then (8388608 + m) `shiftL` up else (8388608 + m) `shiftR` negate up

-- | The two signals each stereo mode codes: left and right, left and side, side and right, mid and side, where
-- signals 1 and 2 are the channels, 3 is the mid and 4 the side.
modeSignals :: [[Int]]
modeSignals = [[1, 2], [1, 4], [4, 2], [3, 4]]

mid, side :: U.Vector Int -> U.Vector Int -> U.Vector Int
mid = U.zipWith (\l r -> (l + r) `shiftR` 1)
side = U.zipWith (-)

-- | Left and right from the two signals of a stereo mode.
unpair :: Int -> [U.Vector Int] -> [U.Vector Int]
unpair m [a, b] = case m of
  0 -> [a, b]
  1 -> [a, U.zipWith (-) a b]
  2 -> [U.zipWith (+) a b, b]
  _ -> [U.zipWith (\x y -> (2 * x + y .&. 1 + y) `shiftR` 1) a b, U.zipWith (\x y -> (2 * x + y .&. 1 - y) `shiftR` 1) a b]
unpair _ signals = signals

encodeStream :: (Int -> U.Vector Int -> U.Vector Int -> S.Vector Word8) -> Prepared -> S.Vector Word8
encodeStream enc p = S.concat ([header, modeBytes] ++ map (word32 . S.length) chosen ++ chosen)
  where
    n = pFrames p
    width = if pFloat p then 32 else pDepth p
    chans = pCoded p
    nch = length chans
    pair = nch == 2
    coupled = pair && case pModes p of { [a, b] -> a == b; _ -> True }
    signals = [(c, width) | c <- chans] ++ case chans of
      [l, r] | coupled -> [(mid l r, width), (side l r, width + 1)]
      _ -> []
    coded = parMapNF (\s -> [enc d (U.slice (max 0 (s - maxHistory)) (min s maxHistory) c) (U.slice s (min maxBlock (n - s)) c) | (c, d) <- signals])
              [0, maxBlock .. n - 1]
    cost bs m = sum [S.length (bs !! (k - 1)) | k <- modeSignals !! m]
    choice bs = if coupled then foldl (\best m -> if cost bs m < cost bs best then m else best) 0 [1 .. 3] else 0
    modes = map choice coded
    chosen = concat [if pair then [bs !! (k - 1) | k <- modeSignals !! m] else bs | (bs, m) <- zip coded modes]
    modeBytes = if pair then S.fromList (map pack (quads modes)) else S.empty
    pack q = fromIntegral (foldl (\a m -> a `shiftL` 2 .|. m) 0 (take 4 (q ++ repeat 0)))
    quads [] = []
    quads xs = take 4 xs : quads (drop 4 xs)
    header = S.concat
      [ word32 n
      , S.fromList ([fromIntegral nch, fromIntegral (pDepth p), if pFloat p then 1 else 0]
                    ++ concat [[fromIntegral m, fromIntegral s] | (m, s) <- pModes p])
      ]

decodeStream :: (Int -> U.Vector Int -> Int -> S.Vector Word8 -> U.Vector Int) -> S.Vector Word8 -> [U.Vector Int]
decodeStream dec v = map (U.concat . reverse) (go 0 (replicate nch []))
  where
    n = readWord32 v 0
    nch = fromIntegral (S.unsafeIndex v 4)
    float = S.unsafeIndex v 6 == 1
    width = if float then 32 else fromIntegral (S.unsafeIndex v 5)
    pair = nch == 2
    modesAt = 7 + (if float then 2 * nch else 0)
    lengths = V.fromList [min maxBlock (n - s) | s <- [0, maxBlock .. n - 1]]
    groups = V.length lengths
    sizesAt = modesAt + (if pair then (2 * groups + 7) `quot` 8 else 0)
    sizes = [readWord32 v (sizesAt + 4 * i) | i <- [0 .. nch * groups - 1]]
    offsets = scanl (+) (sizesAt + 4 * nch * groups) sizes
    blocks = V.fromList (zipWith (\o l -> S.slice o l v) offsets sizes)
    modeOf g = if pair then fromIntegral (getBits v (8 * modesAt + 2 * g) 2) else 0
    signalOf i = if pair then modeSignals !! modeOf (i `quot` 2) !! (i `rem` 2) else i `rem` nch + 1
    depthOf i = if pair && signalOf i == 4 then width + 1 else width
    alone = V.fromList (parMapNF (\i -> if usesHistory (blocks V.! i) then Nothing
                                        else Just (dec (depthOf i) U.empty (lengths V.! (i `quot` nch)) (blocks V.! i)))
                                 [0 .. nch * groups - 1])
    go g outs
      | g == groups = outs
      | otherwise =
          let got = [fromMaybe (dec (depthOf i) (recent (signalOf i) outs) (lengths V.! g) (blocks V.! i)) (alone V.! i)
                    | c <- [0 .. nch - 1], let i = g * nch + c]
              new = if pair then unpair (modeOf g) got else got
          in foldr seq () new `seq` go (g + 1) (zipWith (:) new outs)
    recent k outs = case outs of
      [l, r] | pair && k == 3 -> mid (latest l) (latest r)
             | pair && k == 4 -> side (latest l) (latest r)
      _ -> latest (outs !! (k - 1))
    latest done = U.concat (gather maxHistory done [])
    gather _ [] got = got
    gather need (b : bs) got
      | need <= 0 = got
      | U.length b >= need = U.drop (U.length b - need) b : got
      | otherwise = gather (need - U.length b) bs (b : got)
