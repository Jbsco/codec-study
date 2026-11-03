--  Reading the block codec's stream from its own bytes: the header, each group's framing and block table, and
--  the blocks. Every field is checked against the bytes left before it is read, so a damaged or foreign file
--  ends in a status, not an exception. A group whose framing fails is skipped, the next group is found again by
--  its sync word, and the frames between are marked lost.
with Ada.Strings.Unbounded;
with Audio_Digest;
with Bit_Streams; use Bit_Streams;
with Block_Codec; use Block_Codec;
with Stream_Format; use Stream_Format;

package Stream_Reading is

   type Natural_List is array (1 .. Max_Channels) of Natural;
   type Seek_Entry is record
      Frame, Offset : Natural := 0;
   end record;
   type Seek_List is array (Positive range <>) of Seek_Entry;
   type Seek_List_Access is access Seek_List;
   type Boolean_Array is array (Natural range <>) of Boolean;
   type Boolean_Array_Access is access Boolean_Array;
   type Channel_Buffers is array (1 .. Max_Channels) of Sample_Array_Access;

   --  The header's fields. Ok when the magic, the version, every field's range and the CRC are right.
   type Header is record
      Ok : Boolean := False;
      Independent : Boolean := False;
      Rate, Frames, Channels, Depth, Valid_Bits : Natural := 0;
      Is_Float : Boolean := False;
      Channel_Mask : Long_Long_Integer := 0;
      Audio_Md5 : Audio_Digest.Digest := Audio_Digest.Not_Recorded;
      Modes, Scales : Natural_List := [others => 0];
      Tag_Count : Natural := 0;
      Tags : Ada.Strings.Unbounded.Unbounded_String;
      Seeks : Seek_List_Access;
      Source : Byte_Array_Access;
      First_Group : Natural := 0;
   end record;

   --  Depth of the coded channels, and of coded signal S: one bit more for the side of a pair.
   function Coded_Depth (H : Header) return Sample_Bits is (if H.Is_Float then 32 else Sample_Bits (H.Depth))
     with Pre => H.Ok;
   function Signal_Depth (H : Header; S : Positive) return Sample_Bits is
     (if S > H.Channels and then (S - H.Channels) mod 2 = 0 then Coded_Depth (H) + 1 else Coded_Depth (H))
     with Pre => H.Ok;

   procedure Read_Header (Stream : Byte_Array; H : out Header)
     with Pre => Stream'First = 0;

   --  Free what Read_Header allocated in H.
   procedure Release (H : in out Header);

   --  Sample F of channel C in the form Wav_Files reads it: the integer, or for float the order-keeping integer of
   --  its bit pattern.
   function Wav_Sample (H : Header; Output : Channel_Buffers; C : Positive; F : Natural) return Long_Long_Integer is
     (if H.Is_Float and then H.Modes (C) = 1 then From_Integer (Output (C) (F), H.Scales (C)) else Output (C) (F));

   --  The decoded audio against the MD5 the header records: not checked, none recorded, or the result.
   type Audio_Check is (Not_Checked, Not_Recorded, Matches, Differs);

   --  What a full decode met: groups whose framing failed, blocks whose CRC failed, frames in no readable group,
   --  whether every block decoded and used its whole length, whether the groups covered every frame, and the
   --  audio check.
   type Damage is record
      Bad_Groups, Bad_Crcs, Lost_Frames : Natural := 0;
      Blocks_Ok : Boolean := True;
      Complete : Boolean := False;
      Audio : Audio_Check := Not_Checked;
   end record;

   --  Decode every group into Output, H.Frames samples per channel; Lost marks the frames no group gave. With
   --  Verify, the MD5 of the decoded audio is checked against the header's.
   procedure Decode_All (Stream : Byte_Array; H : Header; Output : out Channel_Buffers; Lost : out Boolean_Array_Access;
                         D : out Damage; Verify : Boolean := True)
     with Pre => Stream'First = 0 and then H.Ok;

   --  Decode from the seek point at or before frame Target until the group that holds it, into Buf. Floor is
   --  the first frame decoded, Hops the groups skipped by their lengths, Count the groups decoded, and Last_First
   --  and Last_Count the frames of the last group decoded.
   procedure Decode_From (Stream : Byte_Array; H : Header; Target : Natural; Buf : out Channel_Buffers;
                          Floor, Hops, Count, Last_First, Last_Count : out Natural; Ok : out Boolean)
     with Pre => Stream'First = 0 and then H.Ok and then Target < H.Frames;

   --  A decoder for frames asked for in order. It decodes group by group and keeps only the samples later blocks may
   --  read, so its memory does not grow with the stream's frame count. Frames of groups that cannot be read, and of
   --  groups missing at the end, read as zeros.
   type Walker is limited private;

   procedure Start (W : in out Walker; Stream : Byte_Array_Access; H : Header)
     with Pre => H.Ok and then Stream /= null and then Stream'First = 0;

   --  Make every frame up to Upto final.
   procedure Advance (W : in out Walker; Upto : Natural)
     with Inline;

   --  Sample F of channel C, after Advance (W, F) and before any frame more than the history length later is asked
   --  for; zero for a lost frame.
   function Value (W : Walker; C : Positive; F : Natural) return Long_Long_Integer
     with Inline;

   function Report (W : Walker) return Damage;

   --  Free the walker's buffers. Start it again before any other call.
   procedure Stop (W : in out Walker);

private

   --  Scratch space of a decode: one block per channel, and the history of a mid or side signal.
   type Scratch is record
      Got : Channel_Buffers;
      Derived : Sample_Array_Access;
   end record;

   --  Window frames per channel: the history and eight groups.
   Window : constant := Max_History + 8 * Max_Block;

   type Walker is limited record
      Stream : Byte_Array_Access;
      H : Header;
      Work : Scratch;
      Buf : Channel_Buffers;
      Base : Natural := 0;
      Filled, Offset : Natural := 0;
      D : Damage;
   end record;

end Stream_Reading;
