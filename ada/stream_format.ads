--  Constants and mappings of the block codec's stream that the encoder and the reader share: the header's magic
--  and version, the group framing, the split tree, the stereo modes of each channel pair, and the float maps.
with Bit_Streams; use Bit_Streams;
with Block_Codec; use Block_Codec;

package Stream_Format is

   type Byte_Array_Access is access Byte_Array;
   type Sample_Array_Access is access Sample_Array;

   Magic : constant Byte_Array (0 .. 3) := [16#42#, 16#4C#, 16#4B#, 16#43#];
   Version : constant := 2;
   Sync : constant := 16#B1C5#;
   Group_Head : constant := 11;
   Tag_Block : constant := 1;
   Seek_Block : constant := 2;
   Max_Channels : constant := 8;
   Max_Pairs : constant := Max_Channels / 2;

   --  Each group of 4096 frames splits into blocks of 4096, 2048, 1024 or 512 frames.
   Top : constant := 3;

   type Mode_List is array (1 .. Max_Pairs) of Natural;
   type Leaf is record
      First, Count : Natural := 0;
      Modes : Mode_List := [others => 0];
   end record;
   type Leaf_List is array (0 .. 2**Top - 1) of Leaf;

   --  The two signals each stereo mode codes: left and right, left and side, side and right, mid and side, where
   --  signals 1 and 2 are the channels, 3 is the mid and 4 the side.
   Mode_Signals : constant array (0 .. 3, 1 .. 2) of Positive := [[1, 2], [1, 4], [4, 2], [3, 4]];

   --  A node of a group's split tree is whole when it is a smallest block or its second half starts before the
   --  frame Upto.
   function Whole (First, Level, Upto : Natural) return Boolean is
     (Level = Top or else First + Max_Block / 2**(Level + 1) < Upto);

   --  V divided by two, rounded down.
   function Half_Down (V : Long_Long_Integer) return Long_Long_Integer is (if V >= 0 then V / 2 else -((1 - V) / 2));

   --  The pair of channel C, 0 for a channel coded alone; signal S of pair P, 1 and 2 its channels, 3 its mid and
   --  4 its side; the signal a mode's position K of pair P names; and the signal that codes channel C.
   function Pair_Of (C : Positive; Pairs : Natural) return Natural is (if C <= 2 * Pairs then (C + 1) / 2 else 0);
   function Pair_Signal (P, S : Positive; Channels : Natural) return Positive is
     (case S is when 1 => 2 * P - 1, when 2 => 2 * P, when 3 => Channels + 2 * P - 1, when others => Channels + 2 * P);
   function Signal_Of (P : Positive; M : Natural; K : Positive; Channels : Natural) return Positive is
     (Pair_Signal (P, Mode_Signals (M, K), Channels));
   function Coded_Signal (C : Positive; Modes : Mode_List; Channels : Natural) return Positive is
     (if Pair_Of (C, Channels / 2) = 0 then C
      else Signal_Of (Pair_Of (C, Channels / 2), Modes (Pair_Of (C, Channels / 2)), C - 2 * (Pair_Of (C, Channels / 2) - 1), Channels));

   --  Float bit patterns from the order-keeping integers of Wav_Files, and back.
   function Bits_Of (V : Long_Long_Integer) return Long_Long_Integer is (if V >= 0 then V else 2**31 - 1 - V);
   function Ordered (B : Long_Long_Integer) return Long_Long_Integer is (if B >= 2**31 then 2**31 - 1 - B else B);

   --  The order-keeping integer of the float I / 2**S.
   function From_Integer (I : Long_Long_Integer; S : Natural) return Long_Long_Integer;

end Stream_Format;
