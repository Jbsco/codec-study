--  Reading the block codec's stream from its own bytes: the header, each group's framing and block table, and
--  the blocks. Every field is checked against the bytes left before it is read, so a damaged or foreign file
--  ends in a status, not an exception. A group whose framing fails is skipped, the next group is found again by
--  its sync word, and the frames between are marked lost.
with Ada.Strings.Unbounded;
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
      Rate, Frames, Channels, Depth : Natural := 0;
      Is_Float : Boolean := False;
      Modes, Scales : Natural_List := [others => 0];
      Tag_Count : Natural := 0;
      Tags : Ada.Strings.Unbounded.Unbounded_String;
      Seeks : Seek_List_Access;
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

   --  What a full decode met: groups whose framing failed, blocks whose CRC failed, frames in no readable group,
   --  whether every block decoded and used its whole length, and whether the groups covered every frame.
   type Damage is record
      Bad_Groups, Bad_Crcs, Lost_Frames : Natural := 0;
      Blocks_Ok : Boolean := True;
      Complete : Boolean := False;
   end record;

   --  Decode every group into Output, H.Frames samples per channel; Lost marks the frames no group gave.
   procedure Decode_All (Stream : Byte_Array; H : Header; Output : out Channel_Buffers; Lost : out Boolean_Array_Access;
                         D : out Damage)
     with Pre => Stream'First = 0 and then H.Ok;

   --  Decode from the seek point at or before frame Target until the group that holds it, into Buf. Floor is
   --  the first frame decoded, Hops the groups skipped by their lengths, Count the groups decoded, and Last_First
   --  and Last_Count the frames of the last group decoded.
   procedure Decode_From (Stream : Byte_Array; H : Header; Target : Natural; Buf : out Channel_Buffers;
                          Floor, Hops, Count, Last_First, Last_Count : out Natural; Ok : out Boolean)
     with Pre => Stream'First = 0 and then H.Ok and then Target < H.Frames;

end Stream_Reading;
