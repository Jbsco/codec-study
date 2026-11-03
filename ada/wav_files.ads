--  WAV output, and input from WAV, RF64, Wave64 and AIFF, at 8, 16, 24 and 32-bit integer and 32-bit float, one array
--  per channel. Float samples become integers through their bit patterns in an order-keeping map: a pattern with the
--  sign bit set becomes minus its other 31 bits, minus one.
with Huffman_Codes; use Huffman_Codes;

package Wav_Files is

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
   end record;

   --  Read up to Max_Seconds from the start of the data chunk. Valid_Bits and Channel_Mask come from the extensible
   --  format header; a plain one gives the depth and no mask.
   procedure Read (Name : String; Max_Seconds : Natural; Result : out Audio);

   --  Write a WAV file of Frames frames, taking each sample from Sample (C, F) in the form Read gives it: the
   --  integer, or for float the order-keeping integer of its bit pattern. More than two channels, more than 16
   --  bits, valid bits below the depth or a channel mask get the extensible format header.
   procedure Write (Name : String; Channels, Rate, Depth, Valid_Bits : Positive; Channel_Mask : Long_Long_Integer;
                    Is_Float : Boolean; Frames : Natural;
                    Sample : not null access function (C : Positive; F : Natural) return Long_Long_Integer)
     with Pre => Channels <= Max_Channels and then Valid_Bits <= Depth
       and then (if Is_Float then Depth = 32 else Depth in 8 | 16 | 24 | 32);

end Wav_Files;
