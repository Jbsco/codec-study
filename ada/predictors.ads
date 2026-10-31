--  Prediction residuals: the fixed polynomial predictors of FLAC, and tiers in which the first sample of
--  each group of a tier forms the next, coarser tier.
with Bit_Streams; use Bit_Streams;
with Huffman_Codes; use Huffman_Codes;

package Predictors is

   subtype Fixed_Order is Natural range 0 .. 4;

   --  The polynomial prediction of X (N) from the samples before it, with samples before the start taken as zero.
   function Predict (X : Value_Array; N : Natural; Order : Fixed_Order) return Long_Long_Integer;

   --  The order with the least absolute residual over X (First .. Last).
   function Best_Order (X : Value_Array; First, Last : Natural) return Fixed_Order;

   --  The samples of a group as offsets from its first sample, as differences from the sample before, or
   --  (pairs only) the second sample as an offset from the mean of the first samples of its pair and the next.
   type Tier_Mode is (From_Start, Successive, Mean_Of_Anchors);

   --  Code X as tiers of groups of Group samples, coarsest tier first, each tier with its own Huffman table.
   --  Finest_Bits is the size of the finest tier.
   procedure Encode_Tiers (X : Value_Array; Group : Positive; Mode : Tier_Mode; Buffer : in out Byte_Array; Pos : in out Natural; Finest_Bits : out Natural)
     with Pre => Group >= 2 and then (Mode /= Mean_Of_Anchors or else Group = 2);

   procedure Decode_Tiers (Buffer : Byte_Array; Pos : in out Natural; Group : Positive; Mode : Tier_Mode; X : out Value_Array)
     with Pre => Group >= 2 and then (Mode /= Mean_Of_Anchors or else Group = 2);

end Predictors;
