with Ada.Directories;
with Ada.Streams.Stream_IO;
with Ada.Unchecked_Deallocation;

package body Wav_Files is

   use Ada.Streams;

   type Element_Array_Access is access Stream_Element_Array;
   procedure Free is new Ada.Unchecked_Deallocation (Stream_Element_Array, Element_Array_Access);

   procedure Read (Name : String; Max_Seconds : Natural; Result : out Audio) is
      Size : constant Stream_Element_Offset := Stream_Element_Offset (Ada.Directories.Size (Name));
      Data : Element_Array_Access := new Stream_Element_Array (0 .. Size - 1);
      File : Stream_IO.File_Type;
      Last : Stream_Element_Offset;
      Chunk : Stream_Element_Offset := 12;
      Format : Natural := 0;

      function U16 (Offset : Stream_Element_Offset) return Long_Long_Integer is
        (Long_Long_Integer (Data (Offset)) + 256 * Long_Long_Integer (Data (Offset + 1)));
      function U32 (Offset : Stream_Element_Offset) return Long_Long_Integer is (U16 (Offset) + 65536 * U16 (Offset + 2));
      function Id (Offset : Stream_Element_Offset) return String is
        (Character'Val (Natural (Data (Offset))) & Character'Val (Natural (Data (Offset + 1)))
         & Character'Val (Natural (Data (Offset + 2))) & Character'Val (Natural (Data (Offset + 3))));
   begin
      Stream_IO.Open (File, Stream_IO.In_File, Name);
      Stream_IO.Read (File, Data.all, Last);
      Stream_IO.Close (File);
      if Id (0) /= "RIFF" or else Id (8) /= "WAVE" then
         raise Constraint_Error with Name & ": not a WAV file";
      end if;
      while Chunk + 8 <= Last loop
         declare
            Length : constant Stream_Element_Offset := Stream_Element_Offset (U32 (Chunk + 4));
            Start : constant Stream_Element_Offset := Chunk + 8;
         begin
            if Id (Chunk) = "fmt " then
               Format := Natural (U16 (Start));
               if Format = 16#FFFE# then
                  Format := Natural (U16 (Start + 24));
               end if;
               Result.Channels := Natural (U16 (Start + 2));
               Result.Rate := Natural (U32 (Start + 4));
               Result.Depth := Natural (U16 (Start + 14));
               Result.Is_Float := Format = 3;
               if not ((Format = 1 and then Result.Depth in 8 | 16 | 24 | 32) or else (Format = 3 and then Result.Depth = 32))
                 or else Result.Channels > Max_Channels
               then
                  raise Constraint_Error with Name & ": only 8 to 32-bit integer and 32-bit float PCM are read";
               end if;
            elsif Id (Chunk) = "data" and then Format /= 0 then
               declare
                  Width : constant Natural := Result.Depth / 8;
                  Frames : constant Natural := Natural'Min (Natural (Length) / (Width * Result.Channels), Max_Seconds * Result.Rate);
                  Half : constant Long_Long_Integer := 2**(Result.Depth - 1);
               begin
                  Result.Frames := Frames;
                  for C in 1 .. Result.Channels loop
                     Result.Samples (C) := new Value_Array (0 .. Frames - 1);
                  end loop;
                  for F in 0 .. Frames - 1 loop
                     for C in 1 .. Result.Channels loop
                        declare
                           Offset : constant Stream_Element_Offset := Start + Stream_Element_Offset ((F * Result.Channels + C - 1) * Width);
                           Raw : Long_Long_Integer := 0;
                        begin
                           for B in reverse 0 .. Width - 1 loop
                              Raw := Raw * 256 + Long_Long_Integer (Data (Offset + Stream_Element_Offset (B)));
                           end loop;
                           Result.Samples (C) (F) :=
                             (if Result.Is_Float then (if Raw >= Half then Half - 1 - Raw else Raw)
                              elsif Width = 1 then Raw - 128
                              elsif Raw >= Half then Raw - 2 * Half
                              else Raw);
                        end;
                     end loop;
                  end loop;
               end;
               Free (Data);
               return;
            end if;
            Chunk := Start + Length + Length mod 2;
         end;
      end loop;
      raise Constraint_Error with Name & ": no data chunk";
   end Read;

end Wav_Files;
