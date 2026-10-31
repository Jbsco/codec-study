--  Check that the stream's CRCs catch damage: with no damage every CRC matches; a flipped bit before the block
--  table fails the header CRC; a flipped bit inside a block fails that block's CRC and no other. Reads a stream
--  written by codec_main --stream and walks its block table the way a decoder does.
--  Usage: corrupt_test <stream.bin> <blocks>
with Ada.Command_Line;
with Ada.Direct_IO;
with Ada.Text_IO;
with Bit_Streams; use Bit_Streams;
with Checksums;

procedure Corrupt_Test is
   package Byte_IO is new Ada.Direct_IO (Byte);
   File : Byte_IO.File_Type;
   Size : Natural;
   Blocks : constant Natural := Natural'Value (Ada.Command_Line.Argument (2));
   Failures : Natural := 0;

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
      Front_End : Natural := 0;
      Bad : Natural := 0;

      function Entry_At (B, Field : Natural) return Natural is
        (Natural (Stream (Front_End + 2 + 4 * B + Field)) * 256 + Natural (Stream (Front_End + 3 + 4 * B + Field)));

      function Block_Crc_Matches (B, Offset : Natural) return Boolean is
        (Checksums.Matches (Stream, Front_End + 4 + 4 * B, Checksums.Of_Bytes (Stream (Offset .. Offset + Entry_At (B, 0) - 1))));
   begin
      for I in Stream'Range loop
         Byte_IO.Read (File, Stream (I));
      end loop;
      Byte_IO.Close (File);
      --  The header CRC sits where the two bytes after a prefix equal that prefix's CRC and the block table that
      --  follows describes exactly the rest of the file.
      for Candidate in 7 .. Size - 2 - 4 * Blocks loop
         if Checksums.Matches (Stream, Candidate, Checksums.Of_Bytes (Stream (0 .. Candidate - 1))) then
            declare
               Total : Natural := Candidate + 2 + 4 * Blocks;
            begin
               for B in 0 .. Blocks - 1 loop
                  Total := Total + Natural (Stream (Candidate + 2 + 4 * B)) * 256 + Natural (Stream (Candidate + 3 + 4 * B));
               end loop;
               if Total = Size then
                  Front_End := Candidate;
                  exit;
               end if;
            end;
         end if;
      end loop;
      Expect (Front_End > 0, "the header CRC and the block table are found");
      if Front_End > 0 then
         declare
            Offset : Natural := Front_End + 2 + 4 * Blocks;
            First_Offset : constant Natural := Offset;
            First_Len : constant Natural := Entry_At (0, 0);
         begin
            for B in 0 .. Blocks - 1 loop
               if not Block_Crc_Matches (B, Offset) then
                  Bad := Bad + 1;
               end if;
               Offset := Offset + Entry_At (B, 0);
            end loop;
            Expect (Bad = 0, "no block CRC fails on the stream as written, found" & Bad'Image);
            Stream (5) := Stream (5) xor 16#40#;
            Expect (not Checksums.Matches (Stream, Front_End, Checksums.Of_Bytes (Stream (0 .. Front_End - 1))),
                    "a flipped header bit fails the header CRC");
            Stream (5) := Stream (5) xor 16#40#;
            Stream (First_Offset + First_Len / 2) := Stream (First_Offset + First_Len / 2) xor 16#01#;
            Expect (not Block_Crc_Matches (0, First_Offset), "a flipped bit in block 0 fails its CRC");
            Expect (Blocks < 2 or else Block_Crc_Matches (1, First_Offset + First_Len), "block 1's CRC still matches");
            Expect (Checksums.Matches (Stream, Front_End, Checksums.Of_Bytes (Stream (0 .. Front_End - 1))), "the header CRC still matches");
         end;
      end if;
      Ada.Text_IO.Put_Line ("corrupt_test:" & Blocks'Image & " blocks," & Natural'(6 - Failures)'Image & " of 6 checks passed");
   end;
   if Failures > 0 then
      Ada.Command_Line.Set_Exit_Status (1);
   end if;
end Corrupt_Test;
