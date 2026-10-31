package body Checksums with SPARK_Mode is

   function Step (Crc : Unsigned_16; Data : Byte) return Unsigned_16 is
      Result : Unsigned_16 := Crc xor Shift_Left (Unsigned_16 (Data), 8);
   begin
      for Unused in 1 .. 8 loop
         Result := (if (Result and 16#8000#) /= 0 then Shift_Left (Result, 1) xor Polynomial else Shift_Left (Result, 1));
      end loop;
      return Result;
   end Step;

   type Step_Table is array (Byte) of Unsigned_16;

   --  Table (B) is the CRC of one byte B from a zero register, which is also the effect of B in the high byte.
   function Build return Step_Table is
      T : Step_Table;
   begin
      for B in Byte loop
         T (B) := Step (0, B);
      end loop;
      return T;
   end Build;

   Table : constant Step_Table := Build;

   function Update (Crc : Unsigned_16; Data : Byte_Array; First, Last : Natural) return Unsigned_16 is
      Result : Unsigned_16 := Crc;
   begin
      for I in First .. Last loop
         Result := Shift_Left (Result, 8) xor Table (Byte (Shift_Right (Result, 8)) xor Data (I));
      end loop;
      return Result;
   end Update;

end Checksums;
