-- | The stream of the block codec, as ada/codec_main.adb writes it. A header: the magic "BLKC", a version, a
-- flags byte (bit 0: every group is a segment), the rate and the frames in 32 bits, channels, depth and a float
-- flag in 8 bits each, for float input a mode and a scale per channel, a count of metadata blocks each with a
-- type, a 24-bit length and its bytes (1 tags, 2 a seek table of 32-bit first frames and 64-bit offsets), and a
-- CRC-16 of all that. Then the groups of 4096 frames, each a sync word, a 24-bit byte length, its first frame,
-- its frame count, its split tree down to blocks of 512 frames with a 2-bit stereo mode per channel pair on
-- every leaf, a 16-bit length and a CRC-16 per block, a CRC-16 of the group so far, and the blocks, leaf by leaf
-- and channel by channel. A pair of channels in the same float mode codes each leaf as left and right, left and
-- side, side and right, or mid and side, whichever is shortest. Blocks read earlier samples only within their
-- segment, from one seek point to the next, so a decoder can start at any seek point. Groups encode in parallel
-- with any block coder of the same format. Blocks that need no earlier samples decode in parallel; then the
-- leaves decode the rest in order. A decoder checks every CRC and reports what fails by position.
module Stream (Prepared (..), Level (..), Container (..), levels, prepare, container, encodeStream, decodeStream) where

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
  , pRate :: !Int
  , pDepth :: !Int
  , pFloat :: !Bool
  , pModes :: [(Int, Int)]
  , pCoded :: [U.Vector Int]
  }

prepare :: Audio -> Prepared
prepare a
  | isFloat a =
      let found = map toIntegers (channels a)
      in Prepared (frames a) (rate a) (depth a) True [maybe (2, 0) (\(s, _) -> (1, s)) f | f <- found]
           [maybe c snd f | (f, c) <- zip found (channels a)]
  | otherwise = Prepared (frames a) (rate a) (depth a) False [] (channels a)

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

-- | How the stream is framed: whether every group is its own segment, and the seconds between seek points,
-- 0 for one segment and no seek table.
data Container = Container { cIndependent :: !Bool, cSeekEvery :: !Int }

container :: Container
container = Container False 10

magic :: S.Vector Word8
magic = S.fromList [0x42, 0x4C, 0x4B, 0x43]

version, syncWord, groupHead, seekBlock :: Int
version = 1
syncWord = 0xB1C5
groupHead = 11
seekBlock = 2

-- | The two signals each stereo mode codes: 1 and 2 the pair's channels, 3 its mid and 4 its side.
modeSignals :: [[Int]]
modeSignals = [[1, 2], [1, 4], [4, 2], [3, 4]]

-- | Signals are numbered from 0: the channels, then the mid and the side of each pair.
pairSignal :: Int -> Int -> Int -> Int
pairSignal nch p s = case s of
  1 -> 2 * p
  2 -> 2 * p + 1
  3 -> nch + 2 * p
  _ -> nch + 2 * p + 1

-- | The signal coded for channel c under the leaf's modes, one per pair.
codedSignal :: Int -> Int -> [Int] -> Int -> Int
codedSignal nch pairs modes c
  | c < 2 * pairs = let p = c `quot` 2 in pairSignal nch p (modeSignals !! (modes !! p) !! (c - 2 * p))
  | otherwise = c

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

-- | The channels of a leaf from its coded signals, pair by pair, then the channels coded alone.
unpairAll :: Int -> [Int] -> [U.Vector Int] -> [U.Vector Int]
unpairAll pairs modes got = concat [unpair m [got !! (2 * p), got !! (2 * p + 1)] | (p, m) <- zip [0 ..] modes] ++ drop (2 * pairs) got

-- | The deepest level of a group's split tree: blocks of 4096, 2048, 1024 and 512 frames.
top :: Int
top = 3

-- | The search at each level: the deepest tree level the encoder tries, how it picks a stereo mode (0 left and
-- right only, 1 by an estimate from second differences, 2 by coding all four signals), and its linear prediction
-- effort. Every level writes the same format.
data Level = Level { deepest :: !Int, stereoSearch :: !Int, levelEffort :: !Effort }

levels :: [Level]
levels = [Level 0 0 (Effort 0 15 False False), Level 0 1 (Effort 1 15 False False), Level 1 1 (Effort 2 12 False True),
          Level 2 2 (Effort 4 9 False True), Level 3 2 (Effort 32 5 False True), Level 3 2 (Effort 32 5 True True)]

-- | A group's split tree: a leaf with a stereo mode per pair and its blocks, two halves, or a node that is its
-- first half.
data Node = Leaf [Int] [S.Vector Word8] | Split Node Node | Same Node

instance NFData Node where
  rnf (Leaf ms bs) = rnf ms `seq` rnf bs
  rnf (Split a b) = rnf a `seq` rnf b
  rnf (Same a) = rnf a

-- | A node is whole when it is a smallest block or its second half starts before the frame upto.
whole :: Int -> Int -> Int -> Bool
whole upto first level = level == top || first + maxBlock `shiftR` (level + 1) < upto

word16, word24, word64 :: Int -> S.Vector Word8
word16 x = S.fromList [fromIntegral (x `shiftR` 8), fromIntegral x]
word24 x = S.fromList [fromIntegral (x `shiftR` 16), fromIntegral (x `shiftR` 8), fromIntegral x]
word64 x = S.fromList [fromIntegral (x `shiftR` (8 * k)) | k <- [7, 6 .. 0]]

readWord16, readWord24, readWord64 :: S.Vector Word8 -> Int -> Int
readWord16 v i = fromIntegral (S.unsafeIndex v i) `shiftL` 8 .|. fromIntegral (S.unsafeIndex v (i + 1))
readWord24 v i = fromIntegral (S.unsafeIndex v i) `shiftL` 16 .|. readWord16 v (i + 1)
readWord64 v i = foldl (\acc k -> acc `shiftL` 8 .|. fromIntegral (S.unsafeIndex v (i + k))) 0 [0 .. 7]

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

-- | Groups between seek points, 0 for none, and the first frame of the segment holding a frame.
spans :: Container -> Prepared -> (Int, Int)
spans c p = (tableSpan, if cIndependent c then 1 else tableSpan)
  where
    tableSpan = if cSeekEvery c == 0 then 0 else (cSeekEvery c * (if pRate p > 0 then pRate p else 44100) + maxBlock - 1) `quot` maxBlock

encodeStream :: (Effort -> Int -> U.Vector Int -> U.Vector Int -> S.Vector Word8) -> Level -> Container -> Prepared -> S.Vector Word8
encodeStream enc setting c p = S.concat ([header, word16 (fromIntegral (crc16 header))] ++ groupsCoded)
  where
    n = pFrames p
    width = if pFloat p then 32 else pDepth p
    chans = pCoded p
    nch = length chans
    pairs = nch `quot` 2
    coupled = [case drop (2 * q) (pModes p) of { (a : b : _) -> a == b; _ -> True } | q <- [0 .. pairs - 1]]
    signals = [(ch, width) | ch <- chans]
      ++ concat [[(mid l r, width), (side l r, width + 1)] | q <- [0 .. pairs - 1], let l = chans !! (2 * q), let r = chans !! (2 * q + 1)]
    groups = (n + maxBlock - 1) `quot` maxBlock
    (tableSpan, segmentSpan) = spans c p
    segmentFirst f = if segmentSpan == 0 then 0 else let g = f `quot` maxBlock in (g - g `rem` segmentSpan) * maxBlock
    groupsCoded = parMapNF (\g -> groupBytes g (snd (tree (g * maxBlock) 0))) [0 .. groups - 1]
    tree first level
      | not (whole upto first level) = let (cost0, t) = tree first (level + 1) in (cost0, Same t)
      | level == top = (leafCost, leaf)
      | level < deepest setting && apart < 1 + leafCost = (apart, Split l r)
      | otherwise = (1 + leafCost, leaf)
      where
        upto = min n (first - first `rem` maxBlock + maxBlock)
        size = maxBlock `shiftR` level
        count = min size (n - first)
        from = max (segmentFirst first) (first - maxHistory)
        blocks = V.fromList [enc (levelEffort setting) d (U.slice from (first - from) ch) (U.slice first count ch) | (ch, d) <- signals]
        sizeOf s = S.length (blocks V.! s)
        sums = [U.sum (U.generate (max 0 (count - 2)) (\i -> let j = first + 2 + i in abs (U.unsafeIndex ch j - 2 * U.unsafeIndex ch (j - 1) + U.unsafeIndex ch (j - 2))))
               | (ch, _) <- signals]
        estimated q m = sum [log2' (fromIntegral (sums !! pairSignal nch q k + count)) | k <- modeSignals !! m]
        cost q m = sum [sizeOf (pairSignal nch q k) | k <- modeSignals !! m]
        modeOf q
          | not (coupled !! q) = 0
          | stereoSearch setting == 1 = foldl (\best m -> if estimated q m < estimated q best then m else best) 0 [1 .. 3]
          | stereoSearch setting == 2 = foldl (\best m -> if cost q m < cost q best then m else best) 0 [1 .. 3]
          | otherwise = 0
        modes = map modeOf [0 .. pairs - 1]
        picked = [blocks V.! codedSignal nch pairs modes ch | ch <- [0 .. nch - 1]]
        leafCost = 32 * nch + 2 * pairs + 8 * sum (map S.length picked)
        leaf = Leaf modes picked
        (lc, l) = tree first (level + 1)
        (rc, r) = tree (first + size `shiftR` 1) (level + 1)
        apart = 1 + lc + rc
    flags level (Same t) = flags (level + 1) t
    flags level (Split a b) = (1, 1) : flags (level + 1) a ++ flags (level + 1) b
    flags level (Leaf ms _) = [(0, 1) | level < top] ++ [(m, 2) | m <- ms]
    leaves (Same t) = leaves t
    leaves (Split a b) = leaves a ++ leaves b
    leaves (Leaf _ bs) = bs
    groupBytes g t = S.concat [hd, treeBytes, table, word16 (fromIntegral (crc16 (S.concat [hd, treeBytes, table]))), S.concat bs]
      where
        bs = leaves t
        treeBytes = packBits (flags 0 t)
        first = g * maxBlock
        count = min maxBlock (n - first)
        len = groupHead + S.length treeBytes + 4 * length bs + 2 + sum (map S.length bs)
        hd = S.concat [word16 syncWord, word24 len, word32 first, word16 count]
        table = S.concat (concatMap (\b -> [word16 (S.length b), word16 (fromIntegral (crc16 b))]) bs)
    entries = if tableSpan == 0 then 0 else (groups + tableSpan - 1) `quot` tableSpan
    headerLength = 17 + (if pFloat p then 2 * nch else 0) + 1 + (if entries > 0 then 4 + 12 * entries else 0) + 2
    offsets = V.fromList (scanl (+) headerLength (map S.length groupsCoded))
    seekTable
      | entries == 0 = S.empty
      | otherwise = S.concat (S.fromList [fromIntegral seekBlock] : word24 (12 * entries)
                              : concat [[word32 (e * tableSpan * maxBlock), word64 (offsets V.! (e * tableSpan))] | e <- [0 .. entries - 1]])
    header = S.concat
      [ magic
      , S.fromList [fromIntegral version, if cIndependent c then 1 else 0]
      , word32 (pRate p)
      , word32 n
      , S.fromList ([fromIntegral nch, fromIntegral (pDepth p), if pFloat p then 1 else 0]
                    ++ concat [[fromIntegral m, fromIntegral s] | (m, s) <- pModes p])
      , S.fromList [if entries > 0 then 1 else 0]
      , seekTable
      ]

-- | The decoded channels, and the positions of what fails: -1 for the header CRC, -2 for a seek table entry
-- that does not name a group's offset, -3 - g for group g's header, and the index of a block whose CRC does
-- not match (an empty list when everything matches). A block with a bad CRC decodes anyway.
decodeStream :: (Int -> U.Vector Int -> Int -> S.Vector Word8 -> U.Vector Int) -> S.Vector Word8 -> ([U.Vector Int], [Int])
decodeStream dec v = (map (U.concat . reverse) (go 0 (replicate nch [])), bad)
  where
    nch = fromIntegral (S.unsafeIndex v 14)
    float = S.unsafeIndex v 16 == 1
    width = if float then 32 else fromIntegral (S.unsafeIndex v 15)
    pairs = nch `quot` 2
    metaAt = 17 + (if float then 2 * nch else 0)
    (seekEntries, metaEnd) = meta (fromIntegral (S.unsafeIndex v metaAt)) (metaAt + 1) []
    meta :: Int -> Int -> [(Int, Int)] -> ([(Int, Int)], Int)
    meta 0 pos acc = (acc, pos)
    meta k pos acc =
      let kind = fromIntegral (S.unsafeIndex v pos)
          len = readWord24 v (pos + 1)
          found = [(readWord32 v (pos + 4 + 12 * i), readWord64 v (pos + 8 + 12 * i)) | kind == seekBlock, i <- [0 .. len `quot` 12 - 1]]
      in meta (k - 1 :: Int) (pos + 4 + len) (acc ++ found)
    headerOk = S.take 4 v == magic && S.unsafeIndex v 4 == fromIntegral version && readWord16 v metaEnd == fromIntegral (crc16 (S.take metaEnd v))
    groupList = walkGroups (metaEnd + 2)
    walkGroups o
      | o + groupHead + 2 > S.length v = []
      | otherwise = let g@(len, _, _, _, _) = parseGroup o in (o, g) : (if len < groupHead + 2 || o + len > S.length v then [] else walkGroups (o + len))
    parseGroup o = (len, first, leavesG, blocksG, okG)
      where
        len = readWord24 v (o + 2)
        first = readWord32 v (o + 5)
        cnt = readWord16 v (o + 9)
        (leavesG, bitEnd) = walk (first + cnt) first 0 (8 * (o + groupHead))
        tableAt = (bitEnd + 7) `quot` 8
        nb = nch * length leavesG
        sizes = [readWord16 v (tableAt + 4 * i) | i <- [0 .. nb - 1]]
        crcs = [readWord16 v (tableAt + 4 * i + 2) | i <- [0 .. nb - 1]]
        crcAt = tableAt + 4 * nb
        starts = scanl (+) (crcAt + 2) sizes
        okG = readWord16 v o == syncWord && o + len <= S.length v && last starts == o + len
          && readWord16 v crcAt == fromIntegral (crc16 (S.slice o (crcAt - o) v))
        blocksG = [(S.slice s l v, c) | okG, (s, l, c) <- zip3 starts sizes crcs]
    walk upto first level pos
      | not (whole upto first level) = walk upto first (level + 1) pos
      | level < top && getBits v pos 1 == 1 =
          let (a, p1) = walk upto first (level + 1) (pos + 1)
              (b, p2) = walk upto (first + maxBlock `shiftR` (level + 1)) (level + 1) p1
          in (a ++ b, p2)
      | otherwise =
          let p0 = if level < top then pos + 1 else pos
              ms = [fromIntegral (getBits v (p0 + 2 * q) 2) | q <- [0 .. pairs - 1]]
          in ([(first, min (maxBlock `shiftR` level) (upto - first), ms)], p0 + 2 * pairs)
    leafV = V.fromList (concat [ls | (_, (_, _, ls, _, True)) <- groupList])
    count = V.length leafV
    blocks = V.fromList (concat [map fst bs | (_, (_, _, _, bs, True)) <- groupList])
    bad = [-1 | not headerOk]
          ++ [-2 | (f, off) <- seekEntries, lookup f [(first, o) | (o, (_, first, _, _, True)) <- groupList] /= Just off]
          ++ [-3 - g | (g, (_, (_, _, _, _, False))) <- zip [0 ..] groupList]
          ++ [i | (i, (b, crc)) <- zip [0 ..] (concat [bs | (_, (_, _, _, bs, True)) <- groupList]), fromIntegral (crc16 b) /= crc]
    lengthOf i = let (_, c, _) = leafV V.! (i `quot` nch) in c
    modesOf leaf = let (_, _, ms) = leafV V.! leaf in ms
    signalOf i = codedSignal nch pairs (modesOf (i `quot` nch)) (i `rem` nch)
    depthOf i = let s = signalOf i in if s >= nch && odd (s - nch) then width + 1 else width
    alone = V.fromList (parMapNF (\i -> if usesHistory (blocks V.! i) then Nothing else Just (dec (depthOf i) U.empty (lengthOf i) (blocks V.! i)))
                                 [0 .. nch * count - 1])
    go leaf outs
      | leaf == count = outs
      | otherwise =
          let got = [fromMaybe (dec (depthOf i) (recent (signalOf i) outs) (lengthOf i) (blocks V.! i)) (alone V.! i)
                    | c <- [0 .. nch - 1], let i = leaf * nch + c]
              new = unpairAll pairs (modesOf leaf) got
          in foldr seq () new `seq` go (leaf + 1) (zipWith (:) new outs)
    recent s outs
      | s < nch = latest (outs !! s)
      | even (s - nch) = mid (latest (outs !! (2 * q))) (latest (outs !! (2 * q + 1)))
      | otherwise = side (latest (outs !! (2 * q))) (latest (outs !! (2 * q + 1)))
      where
        q = (s - nch) `quot` 2
    latest done = U.concat (gather maxHistory done [])
    gather _ [] got = got
    gather need (b : bs) got
      | need <= 0 = got
      | U.length b >= need = U.drop (U.length b - need) b : got
      | otherwise = gather (need - U.length b) bs (b : got)
