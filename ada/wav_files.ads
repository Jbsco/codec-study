--  WAV input at 8, 16, 24 and 32-bit integer and 32-bit float, one array per channel. Float samples become
--  integers through their bit patterns in an order-keeping map: a pattern with the sign bit set becomes
--  minus its other 31 bits, minus one.
with Huffman_Codes; use Huffman_Codes;

package Wav_Files is

   Max_Channels : constant := 8;
   type Channel_Array is array (1 .. Max_Channels) of Value_Array_Access;

   type Audio is record
      Channels : Natural := 0;
      Rate : Natural := 0;
      Depth : Natural := 0;
      Is_Float : Boolean := False;
      Frames : Natural := 0;
      Samples : Channel_Array;
   end record;

   --  Read up to Max_Seconds from the start of the data chunk.
   procedure Read (Name : String; Max_Seconds : Natural; Result : out Audio);

end Wav_Files;
