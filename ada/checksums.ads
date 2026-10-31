--  CRC-16 over any bytes, polynomial 16#1021# most significant bit first, initial value 16#FFFF#, no reflection
--  and no final exclusive or (CRC-16/CCITT-FALSE). The table form and the bitwise form give the same result.
with Interfaces; use Interfaces;
with Bit_Streams; use Bit_Streams;

package Checksums with SPARK_Mode is

   Polynomial : constant Unsigned_16 := 16#1021#;
   Initial : constant Unsigned_16 := 16#FFFF#;

   --  The CRC after one more byte, by eight shifts of the register.
   function Step (Crc : Unsigned_16; Data : Byte) return Unsigned_16;

   --  The CRC of Data (First .. Last) after Crc, one table lookup per byte.
   function Update (Crc : Unsigned_16; Data : Byte_Array; First, Last : Natural) return Unsigned_16
     with Pre => First in Data'Range and then Last in Data'Range;

   --  The CRC of a whole byte array from the initial value; of an empty array, the initial value.
   function Of_Bytes (Data : Byte_Array) return Unsigned_16 is
     (if Data'Length = 0 then Initial else Update (Initial, Data, Data'First, Data'Last));

   --  Whether the two bytes at Data (At_Byte .. At_Byte + 1), most significant first, hold Crc.
   function Matches (Data : Byte_Array; At_Byte : Natural; Crc : Unsigned_16) return Boolean is
     (Unsigned_16 (Data (At_Byte)) * 256 + Unsigned_16 (Data (At_Byte + 1)) = Crc)
     with Pre => At_Byte in Data'Range and then At_Byte < Data'Last;

end Checksums;
