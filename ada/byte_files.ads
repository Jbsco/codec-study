--  Whole files in and out, with "-" naming standard input or standard output, so the programs work in pipes.
with Ada.Streams; use Ada.Streams;
with Ada.Streams.Stream_IO;

package Byte_Files is

   type Bytes_Access is access Stream_Element_Array;

   --  The bytes of file Name, or of standard input when Name is "-", indexed from 0.
   function Load (Name : String) return Bytes_Access;

   --  Open Name for writing, or standard output when Name is "-".
   procedure Create (File : in out Stream_IO.File_Type; Name : String);

end Byte_Files;
