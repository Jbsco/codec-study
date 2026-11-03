with Ada.Directories;
with Interfaces; use Interfaces;
with Ada.Streams.Stream_IO;
with Ada.Unchecked_Deallocation;

package body Wav_Files is

   use Ada.Streams;

   type Element_Array_Access is access Stream_Element_Array;
   procedure Free is new Ada.Unchecked_Deallocation (Stream_Element_Array, Element_Array_Access);

   --  Wave64's chunk identifiers: the RIFF and WAVE equivalents and the format and data chunks, as GUIDs.
   type Guid is array (0 .. 15) of Stream_Element;
   W64_Riff : constant Guid := [16#72#, 16#69#, 16#66#, 16#66#, 16#2E#, 16#91#, 16#CF#, 16#11#,
                                16#A5#, 16#D6#, 16#28#, 16#DB#, 16#04#, 16#C1#, 16#00#, 16#00#];
   W64_Wave : constant Guid := [16#77#, 16#61#, 16#76#, 16#65#, 16#F3#, 16#AC#, 16#D3#, 16#11#,
                                16#8C#, 16#D1#, 16#00#, 16#C0#, 16#4F#, 16#8E#, 16#DB#, 16#8A#];
   W64_Fmt : constant Guid := [16#66#, 16#6D#, 16#74#, 16#20#, 16#F3#, 16#AC#, 16#D3#, 16#11#,
                               16#8C#, 16#D1#, 16#00#, 16#C0#, 16#4F#, 16#8E#, 16#DB#, 16#8A#];
   W64_Data : constant Guid := [16#64#, 16#61#, 16#74#, 16#61#, 16#F3#, 16#AC#, 16#D3#, 16#11#,
                                16#8C#, 16#D1#, 16#00#, 16#C0#, 16#4F#, 16#8E#, 16#DB#, 16#8A#];

   procedure Read (Name : String; Max_Seconds : Natural; Result : out Audio) is
      Size : constant Stream_Element_Offset := Stream_Element_Offset (Ada.Directories.Size (Name));
      Data : Element_Array_Access := new Stream_Element_Array (0 .. Size - 1);
      File : Stream_IO.File_Type;
      Last : Stream_Element_Offset;
      Have_Format : Boolean := False;

      --  Unsigned integer of Bytes bytes at Offset, least or most significant byte first.
      function U (Offset : Stream_Element_Offset; Bytes : Positive; Big : Boolean := False) return Long_Long_Integer is
         V : Long_Long_Integer := 0;
      begin
         if Offset < 0 or else Offset + Stream_Element_Offset (Bytes) - 1 > Last then
            raise Constraint_Error with Name & ": truncated header";
         end if;
         for K in 0 .. Bytes - 1 loop
            V := V * 256 + Long_Long_Integer (Data (Offset + Stream_Element_Offset (if Big then K else Bytes - 1 - K)));
         end loop;
         return V;
      end U;
      function U16 (Offset : Stream_Element_Offset) return Long_Long_Integer is (U (Offset, 2));
      function U32 (Offset : Stream_Element_Offset) return Long_Long_Integer is (U (Offset, 4));
      function Id (Offset : Stream_Element_Offset) return String is
        (if Offset + 3 > Last then "" else
           Character'Val (Natural (Data (Offset))) & Character'Val (Natural (Data (Offset + 1)))
         & Character'Val (Natural (Data (Offset + 2))) & Character'Val (Natural (Data (Offset + 3))));
      function Is_Guid (Offset : Stream_Element_Offset; G : Guid) return Boolean is
        (Offset + 15 <= Last and then (for all K in G'Range => Data (Offset + Stream_Element_Offset (K)) = G (K)));

      --  The format fields of a WAVEFORMAT or WAVEFORMATEXTENSIBLE at Start, Length bytes long.
      procedure Wave_Format (Start, Length : Stream_Element_Offset) is
         Format : Natural := Natural (U16 (Start));
      begin
         if Format = 16#FFFE# then
            Format := Natural (U16 (Start + 24));
         end if;
         Result.Channels := Natural (U16 (Start + 2));
         Result.Rate := Natural (U32 (Start + 4));
         Result.Depth := Natural (U16 (Start + 14));
         Result.Is_Float := Format = 3;
         Result.Valid_Bits := Result.Depth;
         Result.Channel_Mask := 0;
         if Natural (U16 (Start)) = 16#FFFE# and then Length >= 24 then
            Result.Valid_Bits := (if U16 (Start + 18) in 1 .. Long_Long_Integer (Result.Depth) then Natural (U16 (Start + 18)) else Result.Depth);
            Result.Channel_Mask := U32 (Start + 20);
         end if;
         if not ((Format = 1 and then Result.Depth in 8 | 16 | 24 | 32) or else (Format = 3 and then Result.Depth = 32))
           or else Result.Channels not in 1 .. Max_Channels
         then
            raise Constraint_Error with Name & ": only 8 to 32-bit integer and 32-bit float PCM are read";
         end if;
         Have_Format := True;
      end Wave_Format;

      --  The samples of a data chunk at Start, Length bytes, in Result's format. AIFF's 8-bit samples are signed
      --  where WAV's are offset by 128.
      procedure Samples (Start, Length : Stream_Element_Offset; Big, Signed_Bytes : Boolean) is
         Width : constant Natural := Result.Depth / 8;
         Available : constant Stream_Element_Offset := Stream_Element_Offset'Min (Length, Last + 1 - Start);
         Frames : constant Natural :=
           Natural (Long_Long_Integer'Min (Long_Long_Integer (Available) / Long_Long_Integer (Width * Result.Channels),
                                           Long_Long_Integer (Max_Seconds) * Long_Long_Integer (Result.Rate)));
         Half : constant Long_Long_Integer := 2**(Result.Depth - 1);
      begin
         if not Have_Format then
            raise Constraint_Error with Name & ": audio data before its format";
         end if;
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
                  for B in 0 .. Width - 1 loop
                     Raw := Raw * 256 + Long_Long_Integer (Data (Offset + Stream_Element_Offset (if Big then B else Width - 1 - B)));
                  end loop;
                  Result.Samples (C) (F) :=
                    (if Result.Is_Float then (if Raw >= Half then Half - 1 - Raw else Raw)
                     elsif Width = 1 and then not Signed_Bytes then Raw - 128
                     elsif Raw >= Half then Raw - 2 * Half
                     else Raw);
               end;
            end loop;
         end loop;
      end Samples;

      --  RIFF, RF64 and BW64: chunks with 32-bit little-endian lengths; RF64 and BW64 give the data length in ds64.
      procedure Read_Riff is
         Chunk : Stream_Element_Offset := 12;
         Data_Size_64 : Long_Long_Integer := -1;
      begin
         while Chunk + 8 <= Last + 1 loop
            declare
               Length : Stream_Element_Offset := Stream_Element_Offset (U32 (Chunk + 4));
               Start : constant Stream_Element_Offset := Chunk + 8;
            begin
               if Id (Chunk) = "ds64" and then Length >= 16 then
                  Data_Size_64 := U32 (Start + 8) + U32 (Start + 12) * 2**32;
               elsif Id (Chunk) = "fmt " then
                  Wave_Format (Start, Length);
               elsif Id (Chunk) = "data" then
                  if Length = 16#FFFF_FFFF# and then Data_Size_64 >= 0 then
                     Length := Stream_Element_Offset (Data_Size_64);
                  end if;
                  Samples (Start, Length, Big => False, Signed_Bytes => False);
                  return;
               end if;
               Chunk := Start + Length + Length mod 2;
            end;
         end loop;
         raise Constraint_Error with Name & ": no data chunk";
      end Read_Riff;

      --  Wave64: GUID chunk identifiers, 64-bit lengths that count the 24-byte chunk header, chunks aligned to 8.
      procedure Read_W64 is
         Chunk : Stream_Element_Offset := 40;
      begin
         while Chunk + 24 <= Last + 1 loop
            declare
               Length : constant Stream_Element_Offset := Stream_Element_Offset (U (Chunk + 16, 8));
               Start : constant Stream_Element_Offset := Chunk + 24;
            begin
               if Length < 24 then
                  raise Constraint_Error with Name & ": bad Wave64 chunk length";
               elsif Is_Guid (Chunk, W64_Fmt) then
                  Wave_Format (Start, Length - 24);
               elsif Is_Guid (Chunk, W64_Data) then
                  Samples (Start, Length - 24, Big => False, Signed_Bytes => False);
                  return;
               end if;
               Chunk := Chunk + (Length + 7) / 8 * 8;
            end;
         end loop;
         raise Constraint_Error with Name & ": no data chunk";
      end Read_W64;

      --  AIFF and AIFF-C: big-endian chunks; the sample size may be any bit count, left-justified in whole bytes;
      --  AIFF-C names its sample coding: big-endian integers, little-endian (sowt) or 32-bit float.
      procedure Read_Aiff is
         Chunk : Stream_Element_Offset := 12;
         Little : Boolean := False;
      begin
         while Chunk + 8 <= Last + 1 loop
            declare
               Length : constant Stream_Element_Offset := Stream_Element_Offset (U (Chunk + 4, 4, Big => True));
               Start : constant Stream_Element_Offset := Chunk + 8;
            begin
               if Id (Chunk) = "COMM" then
                  declare
                     Bits : constant Natural := Natural (U (Start + 6, 2, Big => True));
                     Exponent : constant Long_Long_Integer := U (Start + 8, 2, Big => True) mod 2**15 - 16383;
                     Mantissa : constant Unsigned_64 := Unsigned_64 (U (Start + 10, 4, Big => True)) * 2**32
                                                        + Unsigned_64 (U (Start + 14, 4, Big => True));
                     Kind : constant String := (if Id (8) = "AIFC" and then Length >= 22 then Id (Start + 18) else "NONE");
                  begin
                     Result.Channels := Natural (U (Start, 2, Big => True));
                     Result.Rate := (if Exponent in 0 .. 63 then Natural (Shift_Right (Mantissa, Natural (63 - Exponent))) else 0);
                     Result.Is_Float := Kind in "fl32" | "FL32";
                     Little := Kind = "sowt";
                     Result.Depth := (if Result.Is_Float then 32 else (Bits + 7) / 8 * 8);
                     Result.Valid_Bits := (if Result.Is_Float then 32 else Bits);
                     Result.Channel_Mask := 0;
                     if Kind not in "NONE" | "twos" | "sowt" | "fl32" | "FL32"
                       or else (Result.Is_Float and then Bits /= 32)
                       or else Result.Depth not in 8 | 16 | 24 | 32 or else Bits = 0
                       or else Result.Channels not in 1 .. Max_Channels
                     then
                        raise Constraint_Error with Name & ": only 1 to 32-bit integer and 32-bit float AIFF are read";
                     end if;
                     Have_Format := True;
                  end;
               elsif Id (Chunk) = "SSND" then
                  declare
                     Offset : constant Stream_Element_Offset := Stream_Element_Offset (U (Start, 4, Big => True));
                  begin
                     Samples (Start + 8 + Offset, Length - 8 - Offset, Big => not Little, Signed_Bytes => True);
                     return;
                  end;
               end if;
               Chunk := Start + Length + Length mod 2;
            end;
         end loop;
         raise Constraint_Error with Name & ": no SSND chunk";
      end Read_Aiff;
   begin
      Stream_IO.Open (File, Stream_IO.In_File, Name);
      Stream_IO.Read (File, Data.all, Last);
      Stream_IO.Close (File);
      if Id (0) in "RIFF" | "RF64" | "BW64" and then Id (8) = "WAVE" then
         Read_Riff;
      elsif Is_Guid (0, W64_Riff) and then Is_Guid (24, W64_Wave) then
         Read_W64;
      elsif Id (0) = "FORM" and then Id (8) in "AIFF" | "AIFC" then
         Read_Aiff;
      else
         raise Constraint_Error with Name & ": not a WAV, RF64, Wave64 or AIFF file";
      end if;
      Free (Data);
   end Read;

   procedure Write (Name : String; Channels, Rate, Depth, Valid_Bits : Positive; Channel_Mask : Long_Long_Integer;
                    Is_Float : Boolean; Frames : Natural;
                    Sample : not null access function (C : Positive; F : Natural) return Long_Long_Integer) is
      Width : constant Positive := Depth / 8;
      Data_Bytes : constant Long_Long_Integer := Long_Long_Integer (Frames) * Long_Long_Integer (Channels * Width);
      Extensible : constant Boolean := Channels > 2 or else Depth > 16 or else Valid_Bits /= Depth or else Channel_Mask /= 0;
      Format_Bytes : constant Positive := (if Extensible then 40 else 16);
      Fact_Bytes : constant Natural := (if Is_Float then 12 else 0);
      Riff_Bytes : constant Long_Long_Integer :=
        4 + Long_Long_Integer (8 + Format_Bytes + Fact_Bytes) + 8 + Data_Bytes + Data_Bytes mod 2;
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
         Bytes (Long_Long_Integer (Valid_Bits), 2);
         Bytes (Channel_Mask, 4);
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
