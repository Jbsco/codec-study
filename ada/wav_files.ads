--  WAV output, and input from WAV, RF64, Wave64 and AIFF, at 8, 16, 24 and 32-bit integer and 32 or 64-bit float, one
--  array per channel. Float samples become integers through their 32-bit patterns in an order-keeping map: a pattern
--  with the sign bit set becomes minus its other 31 bits, minus one. A 64-bit float file is read when every sample is
--  exactly a 32-bit float, and written back by widening each one.
with Bit_Streams; use Bit_Streams;
with Huffman_Codes; use Huffman_Codes;

package Wav_Files is

   --  The source description: the container and every chunk in file order, so a decoder can write the file back.
   --  The container in 8 bits (1 RIFF WAV, 2 RF64, 3 BW64, 4 Wave64, 5 AIFF, 6 AIFF-C), its own size field in 64, and
   --  a 16-bit chunk count. Chunk roles: 0 other, 1 format, 2 audio (its body is what precedes the samples), 3 the RF64
   --  size table. Each chunk is its role and identifier length in 8 bits, the identifier, the value of its own length
   --  field in 64 bits, its body length in 32 and the body. Size fields holding 0 or all ones, as a streaming writer
   --  leaves them, are written back as found; the others are computed.
   type Source_Access is access Byte_Array;
   Riff_Wave : constant := 1;
   Rf64_Wave : constant := 2;
   Bw64_Wave : constant := 3;
   Wave64 : constant := 4;
   Aiff : constant := 5;
   Aiff_C : constant := 6;
   Other_Chunk : constant := 0;
   Format_Chunk : constant := 1;
   Audio_Chunk : constant := 2;
   Size_Table_Chunk : constant := 3;
   Max_Source_Bytes : constant := 2**24 - 1;

   Max_Channels : constant := 8;
   type Channel_Array is array (1 .. Max_Channels) of Value_Array_Access;

   type Audio is record
      Channels : Natural := 0;
      Rate : Natural := 0;
      Depth : Natural := 0;
      Is_Float : Boolean := False;
      Valid_Bits : Natural := 0;
      Channel_Mask : Long_Long_Integer := 0;
      Frames : Natural := 0;
      Samples : Channel_Array;
      Source : Source_Access;
      Foreign_Dropped : Boolean := False;
   end record;

   --  Read up to Max_Seconds from the start of the data chunk. Valid_Bits and Channel_Mask come from the extensible
   --  format header; a plain one gives the depth and no mask. Source describes the file; Foreign_Dropped is set when
   --  chunks other than format and audio were too large to keep.
   procedure Read (Name : String; Max_Seconds : Natural; Result : out Audio);

   --  Write the file Source describes, chunk by chunk in its order, with the audio chunk holding Frames frames from
   --  Sample (C, F) in the form Read gives them and every size field recomputed. Written is False, and nothing is
   --  written, when the description is malformed or its format chunk does not describe these samples.
   procedure Write_Source (Name : String; Source : Byte_Array; Channels, Depth, Valid_Bits : Positive; Is_Float : Boolean;
                           Frames : Natural;
                           Sample : not null access function (C : Positive; F : Natural) return Long_Long_Integer;
                           Written : out Boolean)
     with Pre => Channels <= Max_Channels and then Valid_Bits <= Depth and then Depth in 8 | 16 | 24 | 32 | 64;

   --  Write a WAV file of Frames frames, taking each sample from Sample (C, F) in the form Read gives it: the
   --  integer, or for float the order-keeping integer of its bit pattern. More than two channels, more than 16
   --  bits, valid bits below the depth or a channel mask get the extensible format header.
   procedure Write (Name : String; Channels, Rate, Depth, Valid_Bits : Positive; Channel_Mask : Long_Long_Integer;
                    Is_Float : Boolean; Frames : Natural;
                    Sample : not null access function (C : Positive; F : Natural) return Long_Long_Integer)
     with Pre => Channels <= Max_Channels and then Valid_Bits <= Depth
       and then (if Is_Float then Depth in 32 | 64 else Depth in 8 | 16 | 24 | 32);

end Wav_Files;
