--  Bit access to byte buffers, most significant bit first.
with Interfaces; use Interfaces;

package Bit_Streams with SPARK_Mode is

   type Byte is mod 2**8;
   type Byte_Array is array (Natural range <>) of Byte;

   subtype Field_Width is Natural range 0 .. 64;

   function Valid_Buffer (Buffer : Byte_Array) return Boolean is (Buffer'Last < Natural'Last / 8);

   --  The bit at Pos, counted from the first bit of Buffer.
   function Bit_At (Buffer : Byte_Array; Pos : Natural) return Unsigned_64
     with Pre => Valid_Buffer (Buffer) and then Pos < Buffer'Length * 8,
       Post => Bit_At'Result <= 1;

   --  Write the low Count bits of Value at Pos, most significant first.
   procedure Put (Buffer : in out Byte_Array; Pos : in out Natural; Value : Unsigned_64; Count : Field_Width)
     with Pre => Valid_Buffer (Buffer) and then Pos <= Buffer'Length * 8 and then Count <= Buffer'Length * 8 - Pos,
       Post => Pos = Pos'Old + Count;

   --  Read Count bits at Pos, most significant first.
   procedure Get (Buffer : Byte_Array; Pos : in out Natural; Value : out Unsigned_64; Count : Field_Width)
     with Pre => Valid_Buffer (Buffer) and then Pos <= Buffer'Length * 8 and then Count <= Buffer'Length * 8 - Pos,
       Post => Pos = Pos'Old + Count;

end Bit_Streams;
