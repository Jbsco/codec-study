--  Canonical Huffman coding of integer sequences. Every distinct value is a symbol, and the table that
--  lists them precedes the codes in the stream.
with Ada.Unchecked_Deallocation;
with Interfaces; use Interfaces;
with Bit_Streams; use Bit_Streams;
with Canonical_Decoding;

package Huffman_Codes is

   type Value_Array is array (Natural range <>) of Long_Long_Integer;
   type Value_Array_Access is access Value_Array;
   procedure Free is new Ada.Unchecked_Deallocation (Value_Array, Value_Array_Access);

   type Count_Array is array (Natural range <>) of Natural;
   type Length_Array is array (Natural range <>) of Natural;
   type Code_Array is array (Natural range <>) of Unsigned_64;

   --  Bits of tables and coding parameters written since the caller last cleared it.
   Side_Bits : Natural := 0;

   --  Optimal code lengths for counts that are all above zero.
   procedure Code_Lengths (Counts : Count_Array; Lengths : out Length_Array)
     with Pre => Counts'Length > 0 and then Lengths'First = Counts'First and then Lengths'Last = Counts'Last;

   --  Canonical codes in symbol order, as in RFC 1951 section 3.2.2. Length zero marks an unused symbol.
   procedure Canonical_Codes (Lengths : Length_Array; Codes : out Code_Array)
     with Pre => Codes'First = Lengths'First and then Codes'Last = Lengths'Last;

   --  The code of each distinct value in some data.
   type Code_Book is limited private;

   procedure Prepare (Book : in out Code_Book; Data : Value_Array);
   procedure Write_Table (Book : Code_Book; Buffer : in out Byte_Array; Pos : in out Natural);
   procedure Put_Value (Book : Code_Book; Value : Long_Long_Integer; Buffer : in out Byte_Array; Pos : in out Natural);
   function Longest (Book : Code_Book) return Natural;
   procedure Clear (Book : in out Code_Book);

   type Table_Access is access Canonical_Decoding.Table;
   procedure Free is new Ada.Unchecked_Deallocation (Canonical_Decoding.Table, Table_Access);

   --  Read a table written by Write_Table.
   procedure Read_Table (Buffer : Byte_Array; Pos : in out Natural; Table : out Table_Access);

   --  Decode one value. A malformed stream raises Program_Error.
   procedure Get_Value (Buffer : Byte_Array; Pos : in out Natural; Table : Canonical_Decoding.Table; Value : out Long_Long_Integer);

   --  A table for Data, then Data in that code, and the reverse.
   procedure Encode (Data : Value_Array; Buffer : in out Byte_Array; Pos : in out Natural);
   procedure Decode (Buffer : Byte_Array; Pos : in out Natural; Data : out Value_Array);

   --  Elias gamma codes of positive numbers, and the zigzag map of signed values onto naturals.
   procedure Put_Gamma (Buffer : in out Byte_Array; Pos : in out Natural; N : Unsigned_64) with Pre => N > 0;
   procedure Get_Gamma (Buffer : Byte_Array; Pos : in out Natural; N : out Unsigned_64);
   function Zigzag (V : Long_Long_Integer) return Unsigned_64;
   function Unzigzag (U : Unsigned_64) return Long_Long_Integer;

private

   type Length_Array_Access is access Length_Array;
   type Code_Array_Access is access Code_Array;

   type Code_Book is limited record
      Values : Value_Array_Access;
      Lengths : Length_Array_Access;
      Codes : Code_Array_Access;
   end record;

end Huffman_Codes;
