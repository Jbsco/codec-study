-- | The stream of the block codec, as ada/codec_main.adb writes it: frames in 32 bits; channels, depth and a
-- float flag in 8 bits each; for float input a mode and a scale per channel; the index; a CRC-16 of everything
-- so far; a 16-bit byte length and a CRC-16 for every block; then the blocks, leaf by leaf and channel by
-- channel. A decoder checks each block's CRC before decoding it, so one damaged block is found and reported by
-- position and the others still decode. The index holds, for each group of 4096
-- frames, its split tree in pre-order down to blocks of 512 frames: a split bit on every node that has its own
-- second half, and a 2-bit stereo mode on every leaf of a two-channel stream, padded to a byte at the end. A pair
-- of channels in the same float mode codes each leaf as left and right, left and side, side and right, or mid
-- and side, whichever is shortest. Groups encode in parallel with any block coder of the same format. Blocks
-- that need no samples from before them decode in parallel; then the leaves decode the rest in order.
module Stream (Prepared (..), Level (..), levels, prepare, encodeStream, decodeStream) where

import Control.DeepSeq (NFData (..))
import Data.Bits
import qualified Data.Vector as V
import qualified Data.Vector.Storable as S
import qualified Data.Vector.Unboxed as U
import Data.Maybe (fromMaybe)
import Data.Word (Word8)

import BlockCodec (Effort (..), log2', maxBlock, maxHistory, usesHistory)
import Bits (getBits)
import Blocks (readWord32, word32)
import Checksum (crc16)
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

-- | The deepest level of a group's split tree: blocks of 4096, 2048, 1024 and 512 frames.
top :: Int
top = 3

-- | The search at each level: the deepest tree level the encoder tries, how it picks a stereo mode (0 left and
-- right only, 1 by an estimate from second differences, 2 by coding all four signals), and its linear prediction
-- effort. Every level writes the same format.
data Level = Level { deepest :: !Int, stereoSearch :: !Int, levelEffort :: !Effort }

levels :: [Level]
levels = [Level 0 0 (Effort 0 15 False), Level 0 1 (Effort 1 15 False), Level 1 1 (Effort 2 12 False), Level 2 2 (Effort 4 9 False),
          Level 3 2 (Effort 32 5 False), Level 3 2 (Effort 32 5 True)]

-- | A group's split tree: a leaf with its stereo mode and blocks, two halves, or a node that is its first half.
data Node = Leaf !Int [S.Vector Word8] | Split Node Node | Same Node

instance NFData Node where
  rnf (Leaf m bs) = rnf m `seq` rnf bs
  rnf (Split a b) = rnf a `seq` rnf b
  rnf (Same a) = rnf a

-- | A node is whole when it is a smallest block or its second half starts before the last frame.
whole :: Int -> Int -> Int -> Bool
whole n first level = level == top || first + maxBlock `shiftR` (level + 1) < n

word16 :: Int -> S.Vector Word8
word16 x = S.fromList [fromIntegral (x `shiftR` 8), fromIntegral x]

readWord16 :: S.Vector Word8 -> Int -> Int
readWord16 v i = fromIntegral (S.unsafeIndex v i) `shiftL` 8 .|. fromIntegral (S.unsafeIndex v (i + 1))

-- | Fields of up to a few bits, most significant first, padded to a byte.
packBits :: [(Int, Int)] -> S.Vector Word8
packBits = S.fromList . go 0 0
  where
    go :: Int -> Int -> [(Int, Int)] -> [Word8]
    go acc k [] = [fromIntegral (acc `shiftL` (8 - k)) | k > 0]
    go acc k ((x, w) : rest) = emit (acc `shiftL` w .|. x) (k + w) rest
    emit acc k rest
      | k >= 8 = fromIntegral (acc `shiftR` (k - 8)) : emit (acc .&. (bit (k - 8) - 1)) (k - 8) rest
      | otherwise = go acc k rest

encodeStream :: (Effort -> Int -> U.Vector Int -> U.Vector Int -> S.Vector Word8) -> Level -> Prepared -> S.Vector Word8
encodeStream enc setting p = S.concat ([front, word16 (fromIntegral (crc16 front))] ++ concatMap (\b -> [word16 (S.length b), word16 (fromIntegral (crc16 b))]) chosen ++ chosen)
  where
    front = S.concat [header, packBits (concatMap (flags 0) trees)]
    n = pFrames p
    width = if pFloat p then 32 else pDepth p
    chans = pCoded p
    nch = length chans
    pair = nch == 2
    coupled = pair && case pModes p of { [a, b] -> a == b; _ -> True }
    signals = [(c, width) | c <- chans] ++ case chans of
      [l, r] | coupled -> [(mid l r, width), (side l r, width + 1)]
      _ -> []
    trees = parMapNF (\g -> snd (tree (g * maxBlock) 0)) [0 .. (n + maxBlock - 1) `quot` maxBlock - 1]
    tree first level
      | not (whole n first level) = let (c, t) = tree first (level + 1) in (c, Same t)
      | level == top = (leafCost, leaf)
      | level < deepest setting && apart < 1 + leafCost = (apart, Split l r)
      | otherwise = (1 + leafCost, leaf)
      where
        size = maxBlock `shiftR` level
        count = min size (n - first)
        blocks = [enc (levelEffort setting) d (U.slice (max 0 (first - maxHistory)) (min first maxHistory) c) (U.slice first count c) | (c, d) <- signals]
        cost m = sum [S.length (blocks !! (k - 1)) | k <- modeSignals !! m]
        sums = [U.sum (U.generate (max 0 (count - 2)) (\i -> let j = first + 2 + i in abs (U.unsafeIndex c j - 2 * U.unsafeIndex c (j - 1) + U.unsafeIndex c (j - 2))))
               | (c, _) <- signals]
        estimated m = sum [log2' (fromIntegral (sums !! (k - 1) + count)) | k <- modeSignals !! m]
        m0
          | not coupled = 0
          | stereoSearch setting == 1 = foldl (\best m -> if estimated m < estimated best then m else best) 0 [1 .. 3]
          | stereoSearch setting == 2 = foldl (\best m -> if cost m < cost best then m else best) 0 [1 .. 3]
          | otherwise = 0
        picked = if pair then [blocks !! (k - 1) | k <- modeSignals !! m0] else blocks
        leafCost = 32 * nch + (if pair then 2 else 0) + 8 * sum (map S.length picked)
        leaf = Leaf m0 picked
        (lc, l) = tree first (level + 1)
        (rc, r) = tree (first + size `shiftR` 1) (level + 1)
        apart = 1 + lc + rc
    flags level (Same t) = flags (level + 1) t
    flags level (Split a b) = (1, 1) : flags (level + 1) a ++ flags (level + 1) b
    flags level (Leaf m _) = [(0, 1) | level < top] ++ [(m, 2) | pair]
    leaves (Same t) = leaves t
    leaves (Split a b) = leaves a ++ leaves b
    leaves (Leaf _ bs) = bs
    chosen = concatMap leaves trees
    header = S.concat
      [ word32 n
      , S.fromList ([fromIntegral nch, fromIntegral (pDepth p), if pFloat p then 1 else 0]
                    ++ concat [[fromIntegral m, fromIntegral s] | (m, s) <- pModes p])
      ]

-- | The decoded channels, and the positions of the blocks whose CRC does not match (an empty list when the
-- header CRC and every block CRC match). A block with a bad CRC decodes anyway, so the caller sees its length.
decodeStream :: (Int -> U.Vector Int -> Int -> S.Vector Word8 -> U.Vector Int) -> S.Vector Word8 -> ([U.Vector Int], [Int])
decodeStream dec v = (map (U.concat . reverse) (go 0 (replicate nch [])), bad)
  where
    n = readWord32 v 0
    nch = fromIntegral (S.unsafeIndex v 4)
    float = S.unsafeIndex v 6 == 1
    width = if float then 32 else fromIntegral (S.unsafeIndex v 5)
    pair = nch == 2
    groups = (n + maxBlock - 1) `quot` maxBlock
    walk first level pos
      | not (whole n first level) = walk first (level + 1) pos
      | level < top && getBits v pos 1 == 1 =
          let (a, p1) = walk first (level + 1) (pos + 1)
              (b, p2) = walk (first + maxBlock `shiftR` (level + 1)) (level + 1) p1
          in (a ++ b, p2)
      | otherwise =
          let p0 = if level < top then pos + 1 else pos
              (m, p1) = if pair then (fromIntegral (getBits v p0 2), p0 + 2) else (0, p0)
          in ([(first, min (maxBlock `shiftR` level) (n - first), m)], p1)
    walkGroups g pos
      | g == groups = ([], pos)
      | otherwise = let (ls, p) = walk (g * maxBlock) 0 pos
                        (rest, q) = walkGroups (g + 1) p
                    in (ls ++ rest, q)
    (leafList, indexEnd) = walkGroups 0 (8 * (7 + (if float then 2 * nch else 0)))
    leafV = V.fromList leafList
    count = V.length leafV
    frontEnd = (indexEnd + 7) `quot` 8
    sizesAt = frontEnd + 2
    sizes = [readWord16 v (sizesAt + 4 * i) | i <- [0 .. nch * count - 1]]
    crcs = [readWord16 v (sizesAt + 4 * i + 2) | i <- [0 .. nch * count - 1]]
    offsets = scanl (+) (sizesAt + 4 * nch * count) sizes
    blocks = V.fromList (zipWith (\o l -> S.slice o l v) offsets sizes)
    bad = [-1 | readWord16 v frontEnd /= fromIntegral (crc16 (S.take frontEnd v))]
          ++ [i | (i, b, c) <- zip3 [0 ..] (V.toList blocks) crcs, fromIntegral (crc16 b) /= c]
    lengthOf i = let (_, c, _) = leafV V.! (i `quot` nch) in c
    modeOf leaf = let (_, _, m) = leafV V.! leaf in m
    signalOf i = if pair then modeSignals !! modeOf (i `quot` 2) !! (i `rem` 2) else i `rem` nch + 1
    depthOf i = if pair && signalOf i == 4 then width + 1 else width
    alone = V.fromList (parMapNF (\i -> if usesHistory (blocks V.! i) then Nothing else Just (dec (depthOf i) U.empty (lengthOf i) (blocks V.! i)))
                                 [0 .. nch * count - 1])
    go leaf outs
      | leaf == count = outs
      | otherwise =
          let got = [fromMaybe (dec (depthOf i) (recent (signalOf i) outs) (lengthOf i) (blocks V.! i)) (alone V.! i)
                    | c <- [0 .. nch - 1], let i = leaf * nch + c]
              new = if pair then unpair (modeOf leaf) got else got
          in foldr seq () new `seq` go (leaf + 1) (zipWith (:) new outs)
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
