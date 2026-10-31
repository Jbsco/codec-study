--  One block of up to 4096 integer samples. A block holds a constant, or the residuals of one predictor after the
--  low bits that every sample shares are removed: polynomial orders 0 to 4, the distance back to an exact repeat
--  within the block or in the samples before it, tiers of pairs, or linear prediction of order 1 to 32 with
--  quantized coefficients. The residuals take Rice codes or run-length Huffman codes, and the encoder writes
--  whichever combination is shortest. Only a block that repeats the samples before it needs them to decode.
with Bit_Streams; use Bit_Streams;

package Block_Codec with SPARK_Mode is

   Max_Block : constant := 4096;
   Max_History : constant := 16384;
   subtype Block_Length is Positive range 1 .. Max_Block;
   subtype Sample_Bits is Positive range 8 .. 33;
   type Sample_Array is array (Natural range <>) of Long_Long_Integer;
   type Status_Type is (Success, Truncated_Input, Bad_Data);

   --  Half (B) is 2**(B - 1), the bound of a B-bit two's complement value.
   type Power_Table is array (1 .. 40) of Long_Long_Integer;
   Half : constant Power_Table := [1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536, 131072, 262144, 524288, 1048576, 2097152, 4194304, 8388608, 16777216, 33554432, 67108864, 134217728, 268435456, 536870912, 1073741824, 2147483648, 4294967296, 8589934592, 17179869184, 34359738368, 68719476736, 137438953472, 274877906944, 549755813888];

   function In_Range (V : Long_Long_Integer; Bits : Positive) return Boolean is
     (Bits <= 40 and then V >= -Half (Bits) and then V < Half (Bits));

   --  The most bytes Encode writes for N samples.
   function Bound (N : Block_Length) return Positive is (5 * N + 16);

   --  History holds the samples just before X, the latest last.
   procedure Encode (X, History : Sample_Array; Depth : Sample_Bits; Output : in out Byte_Array; Bytes : out Natural)
     with Pre => X'Length in Block_Length and then History'Length <= Max_History
       and then (for all V of X => In_Range (V, Depth)) and then (for all V of History => In_Range (V, Depth))
       and then Valid_Buffer (Output) and then Output'Length >= Bound (X'Length);

   --  History holds the decoded samples just before X, the latest last. Used is the number of bytes the block took.
   procedure Decode (Input : Byte_Array; History : Sample_Array; Depth : Sample_Bits; X : out Sample_Array; Used : out Natural;
                     Status : out Status_Type)
     with Pre => X'Length in Block_Length and then History'Length <= Max_History
       and then (for all V of History => In_Range (V, Depth)) and then Valid_Buffer (Input),
       Post => Used <= Input'Length;

end Block_Codec;
