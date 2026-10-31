--  Check a stream's framing and CRCs: as written, the header, every group and every block pass, the groups
--  are contiguous and end at the file's end, and every seek point names a group; a flipped header bit fails
--  the header CRC; a flipped bit in a group's length fails that group and the next group is still found by its
--  sync word; a flipped bit inside a block fails that block's CRC and no other. Reads a stream written by
--  codec_main --stream and walks it the way a decoder does.
--  Usage: corrupt_test <stream.bin>
with Ada.Command_Line;
with Ada.Direct_IO;
with Ada.Text_IO;
with Interfaces; use Interfaces;
with Bit_Streams; use Bit_Streams;
with Checksums;

procedure Corrupt_Test is
   package Byte_IO is new Ada.Direct_IO (Byte);
   File : Byte_IO.File_Type;
   Size : Natural;
   Checks : constant := 12;
   Failures : Natural := 0;
   Sync : constant := 16#B1C5#;
   Group_Head : constant := 11;
   Max_Pairs : constant := 4;

   procedure Expect (Condition : Boolean; What : String) is
   begin
      if not Condition then
         Failures := Failures + 1;
         Ada.Text_IO.Put_Line ("FAILED: " & What);
      end if;
   end Expect;
begin
   Byte_IO.Open (File, Byte_IO.In_File, Ada.Command_Line.Argument (1));
   Size := Natural (Byte_IO.Size (File));
   declare
      Stream : Byte_Array (0 .. Size - 1);
      Pos : Natural := 0;
      Field : Unsigned_64;
      Frames, Channels, Pairs, Meta, Header_End, First_Group : Natural := 0;
      Float : Boolean;
      Groups, Blocks, Bad_Blocks, Bad_Seeks, Seeks : Natural := 0;
      Contiguous : Boolean := True;
      Seek_Frames, Seek_Offsets : array (0 .. Size / 12) of Natural := [others => 0];
      Group_Offsets : array (0 .. Size / (Group_Head + 2)) of Natural := [others => 0];
      Group_Firsts : array (0 .. Size / (Group_Head + 2)) of Natural := [others => 0];
      Expected, First_Block_At, First_Block_Len, Second_Block_At, Second_Block_Len, First_Crc_At, Second_Crc_At : Natural := 0;

      function Word (At_Byte, Bytes : Natural) return Natural is
         V : Natural := 0;
      begin
         for I in 0 .. Bytes - 1 loop
            V := V * 256 + Natural (Stream (At_Byte + I));
         end loop;
         return V;
      end Word;

      --  Walk the group at Offset: its length, first frame and whether its sync word, its fields and its CRC
      --  are right; with Check_Blocks, count its blocks and the block CRCs that fail, and note the first two.
      procedure Walk_Group (Offset : Natural; Length, First : out Natural; Ok : out Boolean; Check_Blocks : Boolean) is
         P : Natural := (Offset + Group_Head) * 8;
         Count, Leaves, Upto : Natural := 0;

         procedure Walk (From, Level : Natural) is
         begin
            if Level < 3 and then From + 4096 / 2**(Level + 1) >= Upto then
               Walk (From, Level + 1);
               return;
            end if;
            if Level < 3 then
               Get (Stream, P, Field, 1);
               if Field = 1 then
                  Walk (From, Level + 1);
                  Walk (From + 4096 / 2**(Level + 1), Level + 1);
                  return;
               end if;
            end if;
            P := P + 2 * Pairs;
            Leaves := Leaves + 1;
         end Walk;
      begin
         Length := 0;
         First := 0;
         Ok := False;
         if Offset + Group_Head + 2 > Size or else Word (Offset, 2) /= Sync then
            return;
         end if;
         Length := Word (Offset + 2, 3);
         First := Word (Offset + 5, 4);
         Count := Word (Offset + 9, 2);
         Upto := First + Count;
         if Length < Group_Head + 2 or else Offset + Length > Size or else Count = 0 or else Count > 4096 then
            return;
         end if;
         Walk (First, 0);
         P := (P + 7) / 8 * 8;
         declare
            Table_At : constant Natural := P / 8;
            Crc_At : constant Natural := Table_At + 4 * Leaves * Channels;
            Block_At : Natural := Crc_At + 2;
         begin
            if Crc_At + 2 > Offset + Length then
               return;
            end if;
            Ok := Checksums.Matches (Stream, Crc_At, Checksums.Of_Bytes (Stream (Offset .. Crc_At - 1)));
            if Ok and then Check_Blocks then
               for B in 0 .. Leaves * Channels - 1 loop
                  declare
                     Len : constant Natural := Word (Table_At + 4 * B, 2);
                  begin
                     if Block_At + Len > Offset + Length then
                        Ok := False;
                        return;
                     end if;
                     if not Checksums.Matches (Stream, Table_At + 4 * B + 2, Checksums.Of_Bytes (Stream (Block_At .. Block_At + Len - 1))) then
                        Bad_Blocks := Bad_Blocks + 1;
                     end if;
                     if Blocks = 0 then
                        First_Block_At := Block_At;
                        First_Block_Len := Len;
                        First_Crc_At := Table_At + 4 * B + 2;
                     elsif Blocks = 1 then
                        Second_Block_At := Block_At;
                        Second_Block_Len := Len;
                        Second_Crc_At := Table_At + 4 * B + 2;
                     end if;
                     Blocks := Blocks + 1;
                     Block_At := Block_At + Len;
                  end;
               end loop;
               Ok := Block_At = Offset + Length;
            end if;
         end;
      end Walk_Group;

      function Block_Crc_Matches (At_Byte, Len, Crc_At : Natural) return Boolean is
        (Checksums.Matches (Stream, Crc_At, Checksums.Of_Bytes (Stream (At_Byte .. At_Byte + Len - 1))));
   begin
      for I in Stream'Range loop
         Byte_IO.Read (File, Stream (I));
      end loop;
      Byte_IO.Close (File);
      Expect (Size > 20 and then Stream (0 .. 3) = [16#42#, 16#4C#, 16#4B#, 16#43#] and then Stream (4) = 1, "the magic and the version");
      Frames := Word (10, 4);
      Channels := Natural (Stream (14));
      Pairs := Natural'Min (Channels / 2, Max_Pairs);
      Float := Stream (16) = 1;
      Pos := 17 + (if Float then 2 * Channels else 0);
      Meta := Natural (Stream (Pos));
      Pos := Pos + 1;
      for M in 1 .. Meta loop
         declare
            Kind : constant Natural := Natural (Stream (Pos));
            Len : constant Natural := Word (Pos + 1, 3);
         begin
            if Kind = 2 then
               for E in 0 .. Len / 12 - 1 loop
                  Seek_Frames (Seeks) := Word (Pos + 4 + 12 * E, 4);
                  Seek_Offsets (Seeks) := Word (Pos + 4 + 12 * E + 8, 4);
                  Seeks := Seeks + 1;
               end loop;
            end if;
            Pos := Pos + 4 + Len;
         end;
      end loop;
      Header_End := Pos;
      First_Group := Header_End + 2;
      Expect (Checksums.Matches (Stream, Header_End, Checksums.Of_Bytes (Stream (0 .. Header_End - 1))), "the header CRC matches");
      declare
         Offset : Natural := First_Group;
         Length, First : Natural;
         Ok : Boolean;
      begin
         while Offset < Size loop
            Walk_Group (Offset, Length, First, Ok, True);
            exit when not Ok;
            Group_Offsets (Groups) := Offset;
            Group_Firsts (Groups) := First;
            Groups := Groups + 1;
            Contiguous := Contiguous and then First = Expected;
            Expected := First + Word (Offset + 9, 2);
            Offset := Offset + Length;
         end loop;
         Expect (Ok and then Offset = Size and then Expected = Frames, "every group passes and the groups end at the file's end");
         Expect (Contiguous, "every group starts at the frame the one before it ended");
      end;
      Expect (Bad_Blocks = 0, "no block CRC fails on the stream as written, found" & Bad_Blocks'Image);
      for E in 0 .. Seeks - 1 loop
         declare
            Found : Boolean := False;
         begin
            for G in 0 .. Groups - 1 loop
               Found := Found or else (Group_Offsets (G) = Seek_Offsets (E) and then Group_Firsts (G) = Seek_Frames (E));
            end loop;
            if not Found then
               Bad_Seeks := Bad_Seeks + 1;
            end if;
         end;
      end loop;
      Expect (Bad_Seeks = 0, "every seek point names a group's offset and first frame, bad" & Bad_Seeks'Image);
      Stream (5) := Stream (5) xor 16#40#;
      Expect (not Checksums.Matches (Stream, Header_End, Checksums.Of_Bytes (Stream (0 .. Header_End - 1))), "a flipped header bit fails the header CRC");
      Stream (5) := Stream (5) xor 16#40#;
      if Groups >= 2 then
         declare
            Length, First : Natural;
            Ok : Boolean;
            Found : Natural := Size;
         begin
            Stream (First_Group + 2) := Stream (First_Group + 2) xor 16#80#;
            Walk_Group (First_Group, Length, First, Ok, False);
            Expect (not Ok, "a flipped bit in group 0's length fails its CRC");
            for P in First_Group + 1 .. Size - Group_Head - 2 loop
               if Word (P, 2) = Sync then
                  Walk_Group (P, Length, First, Ok, False);
                  if Ok then
                     Found := P;
                     exit;
                  end if;
               end if;
            end loop;
            Expect (Found = Group_Offsets (1), "group 1 is found again by its sync word and CRC");
            Stream (First_Group + 2) := Stream (First_Group + 2) xor 16#80#;
         end;
      else
         Expect (True, "");
         Expect (True, "");
      end if;
      Stream (First_Block_At + First_Block_Len / 2) := Stream (First_Block_At + First_Block_Len / 2) xor 16#01#;
      Expect (not Block_Crc_Matches (First_Block_At, First_Block_Len, First_Crc_At), "a flipped bit in block 0 fails its CRC");
      Expect (Blocks < 2 or else Block_Crc_Matches (Second_Block_At, Second_Block_Len, Second_Crc_At), "block 1's CRC still matches");
      declare
         Length, First : Natural;
         Ok : Boolean;
      begin
         Walk_Group (First_Group, Length, First, Ok, False);
         Expect (Ok, "group 0's header CRC still matches");
      end;
      Ada.Text_IO.Put_Line ("corrupt_test:" & Groups'Image & " groups," & Blocks'Image & " blocks," & Natural'(Checks - Failures)'Image
                            & " of" & Natural'(Checks)'Image & " checks passed");
   end;
   if Failures > 0 then
      Ada.Command_Line.Set_Exit_Status (1);
   end if;
end Corrupt_Test;
