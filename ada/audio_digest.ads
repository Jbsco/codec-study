--  MD5 of audio samples in FLAC's layout, so the digest of a stream's audio equals the one a FLAC file of the same
--  audio records: frames in order with channels interleaved, each integer sample shifted down to its valid bits and
--  written little-endian in as many bytes as those bits need, each float sample as its 32-bit pattern.
with Bit_Streams; use Bit_Streams;

package Audio_Digest is

   subtype Digest is Byte_Array (0 .. 15);
   Not_Recorded : constant Digest := [others => 0];

   --  Sample (C, F) gives each sample in the form Wav_Files reads it: the integer, or for float the order-keeping
   --  integer of its bit pattern.
   function Md5 (Channels : Positive; Frames : Natural; Depth, Valid_Bits : Positive; Is_Float : Boolean;
                 Sample : not null access function (C : Positive; F : Natural) return Long_Long_Integer) return Digest
     with Pre => Valid_Bits <= Depth and then Depth <= 32;

   function Image (D : Digest) return String;

end Audio_Digest;
