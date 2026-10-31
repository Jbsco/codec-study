--  Canonical Huffman decoding from the number of codes of each length and the symbols in code order,
--  as in RFC 1951 section 3.2.2 and puff.c in zlib. No heap, no exceptions.
with Bit_Streams; use Bit_Streams;

package Canonical_Decoding with SPARK_Mode is

   Max_Length : constant := 48;

   type Count_Array is array (1 .. Max_Length) of Natural;
   type Symbol_Array is array (Positive range <>) of Long_Long_Integer;

   --  Counts (L) codes of length L. Symbols holds the symbols sorted by code length, then by value.
   type Table (Size : Natural) is record
      Last_Length : Natural range 0 .. Max_Length := 0;
      Counts : Count_Array := [others => 0];
      Symbols : Symbol_Array (1 .. Size) := [others => 0];
   end record;

   type Status_Type is (Success, Truncated_Input, Bad_Table, Bad_Code);

   --  Decode one symbol at Pos.
   procedure Decode (Input : Byte_Array; Pos : in out Natural; Codes : Table; Value : out Long_Long_Integer; Status : out Status_Type)
     with Pre => Valid_Buffer (Input) and then Pos <= Input'Length * 8,
       Post => Pos <= Input'Length * 8;

end Canonical_Decoding;
