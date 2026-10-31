--  Block coders for prediction residuals: Rice codes with one parameter per block, as in FLAC, and a
--  Huffman code of each residual's bit length followed by its sign and lower bits, as in JPEG.
with Bit_Streams; use Bit_Streams;
with Huffman_Codes; use Huffman_Codes;

package Residual_Coders is

   procedure Put_Rice (Data : Value_Array; Buffer : in out Byte_Array; Pos : in out Natural);
   procedure Get_Rice (Buffer : Byte_Array; Pos : in out Natural; Data : out Value_Array);

   procedure Put_Bit_Length (Data : Value_Array; Buffer : in out Byte_Array; Pos : in out Natural);
   procedure Get_Bit_Length (Buffer : Byte_Array; Pos : in out Natural; Data : out Value_Array);

end Residual_Coders;
