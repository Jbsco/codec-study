--  Check the CRC against the published check value, the bitwise form against the table form on every byte of
--  a pseudo-random buffer, and the effect of one flipped bit. Exits with a non-zero status on a failure.
with Ada.Command_Line;
with Ada.Text_IO;
with Interfaces; use Interfaces;
with Bit_Streams; use Bit_Streams;
with Checksums; use Checksums;

procedure Checksums_Test is
   Check : constant Byte_Array := [16#31#, 16#32#, 16#33#, 16#34#, 16#35#, 16#36#, 16#37#, 16#38#, 16#39#];
   Random : Byte_Array (0 .. 4095);
   State : Unsigned_32 := 2463534242;
   Bitwise : Unsigned_16 := Initial;
   Failures : Natural := 0;

   procedure Expect (Condition : Boolean; What : String) is
   begin
      if not Condition then
         Failures := Failures + 1;
         Ada.Text_IO.Put_Line ("FAILED: " & What);
      end if;
   end Expect;
begin
   Expect (Of_Bytes (Check) = 16#29B1#, "the check value of ""123456789"" is 29B1");
   Expect (Of_Bytes (Check (Check'First .. Check'First - 1)) = Initial, "an empty array gives the initial value");
   for I in Random'Range loop
      State := State xor Shift_Left (State, 13);
      State := State xor Shift_Right (State, 17);
      State := State xor Shift_Left (State, 5);
      Random (I) := Byte (State and 255);
   end loop;
   for I in Random'Range loop
      Bitwise := Step (Bitwise, Random (I));
      Expect (Bitwise = Update (Initial, Random, Random'First, I), "bitwise and table forms agree at byte" & I'Image);
   end loop;
   declare
      Whole : constant Unsigned_16 := Of_Bytes (Random);
      Flipped : Byte_Array := Random;
   begin
      Flipped (1234) := Flipped (1234) xor 16#10#;
      Expect (Of_Bytes (Flipped) /= Whole, "one flipped bit changes the CRC");
      Expect (Update (Update (Initial, Random, 0, 1000), Random, 1001, 4095) = Whole, "two ranges in sequence equal the whole");
   end;
   Ada.Text_IO.Put_Line ("checksums:" & Natural'(4099 - Failures)'Image & " of 4099 checks passed");
   if Failures > 0 then
      Ada.Command_Line.Set_Exit_Status (1);
   end if;
end Checksums_Test;
