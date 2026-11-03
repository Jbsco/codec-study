--  MD5 of audio samples in FLAC's layout, so the digest of a stream's audio equals the one a FLAC file of the same
--  audio records: frames in order with channels interleaved, each integer sample shifted down to its valid bits and
--  written little-endian in as many bytes as those bits need, each float sample as its 32-bit or 64-bit pattern.
with Ada.Streams;
with Bit_Streams; use Bit_Streams;
with GNAT.MD5;

package Audio_Digest is

   subtype Digest is Byte_Array (0 .. 15);
   Not_Recorded : constant Digest := [others => 0];

   --  An MD5 fed one sample at a time, in frame order with channels interleaved. Each sample is in the form Wav_Files
   --  reads it: the integer, or for float the order-keeping integer of its bit pattern.
   type Hasher is limited private;

   procedure Start (H : out Hasher; Depth, Valid_Bits : Positive; Is_Float : Boolean)
     with Pre => Valid_Bits <= Depth and then (Depth <= 32 or else (Is_Float and then Depth = 64));
   procedure Add (H : in out Hasher; V : Long_Long_Integer);
   procedure Finish (H : in out Hasher; Result : out Digest);

   --  The digest of Frames frames taken from Sample (C, F).
   function Md5 (Channels : Positive; Frames : Natural; Depth, Valid_Bits : Positive; Is_Float : Boolean;
                 Sample : not null access function (C : Positive; F : Natural) return Long_Long_Integer) return Digest
     with Pre => Valid_Bits <= Depth and then (Depth <= 32 or else (Is_Float and then Depth = 64));

   function Image (D : Digest) return String;

private

   type Hasher is limited record
      Context : GNAT.MD5.Context := GNAT.MD5.Initial_Context;
      Width : Positive := 1;
      Shift : Natural := 0;
      Is_Float, Is_Double : Boolean := False;
      Buffer : Ada.Streams.Stream_Element_Array (1 .. 65536) := [others => 0];
      Fill : Ada.Streams.Stream_Element_Offset := 0;
   end record;

end Audio_Digest;
