with Ada.Directories;
with Interfaces; use Interfaces;
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

   procedure Write (Name : String; Channels, Rate, Depth : Positive; Is_Float : Boolean; Frames : Natural;
                    Sample : not null access function (C : Positive; F : Natural) return Long_Long_Integer) is
      Width : constant Positive := Depth / 8;
      Data_Bytes : constant Long_Long_Integer := Long_Long_Integer (Frames) * Long_Long_Integer (Channels * Width);
      Extensible : constant Boolean := Channels > 2 or else Depth > 16;
      Format_Bytes : constant Positive := (if Extensible then 40 else 16);
      Fact_Bytes : constant Natural := (if Is_Float then 12 else 0);
      Riff_Bytes : constant Long_Long_Integer :=
        4 + Long_Long_Integer (8 + Format_Bytes + Fact_Bytes) + 8 + Data_Bytes + Data_Bytes mod 2;
      Mask : constant Long_Long_Integer := (case Channels is when 1 => 4, when 2 => 3, when others => 0);
      Subformat_Tail : constant array (1 .. 8) of Long_Long_Integer := [16#80#, 0, 0, 16#AA#, 0, 16#38#, 16#9B#, 16#71#];
      Buffer : Stream_Element_Array (0 .. 65535);
      Fill : Stream_Element_Offset := 0;
      File : Stream_IO.File_Type;

      procedure Flush is
      begin
         Stream_IO.Write (File, Buffer (0 .. Fill - 1));
         Fill := 0;
      end Flush;

      --  Append the low Count bytes of V, least significant first.
      procedure Bytes (V : Long_Long_Integer; Count : Positive) is
         U : Unsigned_64 := Unsigned_64'Mod (V);
      begin
         if Fill + Stream_Element_Offset (Count) > Buffer'Length then
            Flush;
         end if;
         for Unused in 1 .. Count loop
            Buffer (Fill) := Stream_Element (U and 255);
            U := Shift_Right (U, 8);
            Fill := Fill + 1;
         end loop;
      end Bytes;

      procedure Id (Text : String) is
      begin
         for Ch of Text loop
            Bytes (Character'Pos (Ch), 1);
         end loop;
      end Id;
   begin
      if Riff_Bytes > 2**32 - 1 then
         raise Constraint_Error with Name & ": over 4 GB, too large for a WAV file";
      end if;
      Stream_IO.Create (File, Stream_IO.Out_File, Name);
      Id ("RIFF");
      Bytes (Riff_Bytes, 4);
      Id ("WAVEfmt ");
      Bytes (Long_Long_Integer (Format_Bytes), 4);
      Bytes ((if Extensible then 16#FFFE# elsif Is_Float then 3 else 1), 2);
      Bytes (Long_Long_Integer (Channels), 2);
      Bytes (Long_Long_Integer (Rate), 4);
      Bytes (Long_Long_Integer (Rate) * Long_Long_Integer (Channels * Width), 4);
      Bytes (Long_Long_Integer (Channels * Width), 2);
      Bytes (Long_Long_Integer (Depth), 2);
      if Extensible then
         Bytes (22, 2);
         Bytes (Long_Long_Integer (Depth), 2);
         Bytes (Mask, 4);
         Bytes ((if Is_Float then 3 else 1), 4);
         Bytes (16#0000#, 2);
         Bytes (16#0010#, 2);
         for B of Subformat_Tail loop
            Bytes (B, 1);
         end loop;
      end if;
      if Is_Float then
         Id ("fact");
         Bytes (4, 4);
         Bytes (Long_Long_Integer (Frames), 4);
      end if;
      Id ("data");
      Bytes (Data_Bytes, 4);
      for F in 0 .. Frames - 1 loop
         for C in 1 .. Channels loop
            declare
               V : constant Long_Long_Integer := Sample (C, F);
            begin
               Bytes ((if Is_Float then (if V >= 0 then V else 2**31 - 1 - V) elsif Width = 1 then V + 128 else V), Width);
            end;
         end loop;
      end loop;
      if Data_Bytes mod 2 = 1 then
         Bytes (0, 1);
      end if;
      Flush;
      Stream_IO.Close (File);
   end Write;

end Wav_Files;
