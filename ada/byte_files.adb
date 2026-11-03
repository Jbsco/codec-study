with Ada.Directories;
with Ada.Unchecked_Deallocation;

package body Byte_Files is

   procedure Free is new Ada.Unchecked_Deallocation (Stream_Element_Array, Bytes_Access);

   function Load (Name : String) return Bytes_Access is
      File : Stream_IO.File_Type;
      Last : Stream_Element_Offset;
   begin
      if Name /= "-" then
         declare
            Data : constant Bytes_Access :=
              new Stream_Element_Array (0 .. Stream_Element_Offset (Ada.Directories.Size (Name)) - 1);
         begin
            Stream_IO.Open (File, Stream_IO.In_File, Name);
            Stream_IO.Read (File, Data.all, Last);
            Stream_IO.Close (File);
            return Data;
         end;
      end if;
      Stream_IO.Open (File, Stream_IO.In_File, "/dev/stdin");
      declare
         Data : Bytes_Access := new Stream_Element_Array (0 .. 2**20 - 1);
         Fill : Stream_Element_Offset := 0;
      begin
         loop
            if Fill > Data'Last then
               declare
                  Bigger : constant Bytes_Access := new Stream_Element_Array (0 .. 2 * Data'Length - 1);
               begin
                  Bigger (0 .. Data'Last) := Data.all;
                  Free (Data);
                  Data := Bigger;
               end;
            end if;
            Stream_IO.Read (File, Data (Fill .. Data'Last), Last);
            exit when Last < Fill;
            Fill := Last + 1;
         end loop;
         Stream_IO.Close (File);
         declare
            Result : constant Bytes_Access := new Stream_Element_Array'(Data (0 .. Fill - 1));
         begin
            Free (Data);
            return Result;
         end;
      end;
   end Load;

   procedure Create (File : in out Stream_IO.File_Type; Name : String) is
   begin
      Stream_IO.Create (File, Stream_IO.Out_File, (if Name = "-" then "/dev/stdout" else Name));
   end Create;

end Byte_Files;
