with Ada.Directories;
with Interfaces; use Interfaces;
with Ada.Streams.Stream_IO;
with Ada.Unchecked_Deallocation;
with Float_Bits;

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

      --  Integer of Bytes bytes at Offset, least or most significant byte first: unsigned up to 7 bytes, and two's
      --  complement at 8, so a 64-bit field of all ones reads as -1.
      function U (Offset : Stream_Element_Offset; Bytes : Positive; Big : Boolean := False) return Long_Long_Integer is
         V : Unsigned_64 := 0;
      begin
         if Offset < 0 or else Offset + Stream_Element_Offset (Bytes) - 1 > Last then
            raise Constraint_Error with Name & ": truncated header";
         end if;
         for K in 0 .. Bytes - 1 loop
            V := Shift_Left (V, 8) or Unsigned_64 (Data (Offset + Stream_Element_Offset (if Big then K else Bytes - 1 - K)));
         end loop;
         return (if V > Unsigned_64 (Long_Long_Integer'Last) then Long_Long_Integer (V - 2**63) - Long_Long_Integer'Last - 1
                 else Long_Long_Integer (V));
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
         if not ((Format = 1 and then Result.Depth in 8 | 16 | 24 | 32) or else (Format = 3 and then Result.Depth in 32 | 64))
           or else Result.Channels not in 1 .. Max_Channels
         then
            raise Constraint_Error with Name & ": only 8 to 32-bit integer and 32 or 64-bit float PCM are read";
         end if;
         if Result.Is_Float then
            Result.Valid_Bits := Result.Depth;
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
         Half : constant Long_Long_Integer := 2**(Natural'Min (Result.Depth, 32) - 1);
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
                  Double : Unsigned_64 := 0;
                  Single : Unsigned_32;
                  Exact : Boolean;
               begin
                  if Width = 8 then
                     for B in 0 .. 7 loop
                        Double := Double * 256 + Unsigned_64 (Data (Offset + Stream_Element_Offset (if Big then B else 7 - B)));
                     end loop;
                     Float_Bits.Narrow (Double, Single, Exact);
                     if not Exact then
                        raise Constraint_Error with Name & ": 64-bit float samples that are not exactly 32-bit float are not read";
                     end if;
                     Raw := Long_Long_Integer (Single);
                  else
                     for B in 0 .. Width - 1 loop
                        Raw := Raw * 256 + Long_Long_Integer (Data (Offset + Stream_Element_Offset (if Big then B else Width - 1 - B)));
                     end loop;
                  end if;
                  Result.Samples (C) (F) :=
                    (if Result.Is_Float then (if Raw >= 2**31 then 2**31 - 1 - Raw else Raw)
                     elsif Width = 1 and then not Signed_Bytes then Raw - 128
                     elsif Raw >= Half then Raw - 2 * Half
                     else Raw);
               end;
            end loop;
         end loop;
      end Samples;

      --  Every chunk of the file in order, for the source description: its role, where its identifier and body
      --  are, and the value of its own length field.
      type Chunk_Entry is record
         Role : Natural := Other_Chunk;
         Id_At, Body_At, Body_Length : Stream_Element_Offset := 0;
         Id_Length : Natural := 4;
         Length_Field : Long_Long_Integer := 0;
      end record;
      Max_Entries : constant := 1024;
      Entries : array (1 .. Max_Entries) of Chunk_Entry;
      Entry_Count : Natural := 0;
      Kind : Natural := 0;
      Size_Field : Long_Long_Integer := 0;
      Got_Audio : Boolean := False;

      procedure Record_Chunk (Role : Natural; Id_At : Stream_Element_Offset; Id_Length : Natural; Length_Field : Long_Long_Integer;
                              Body_At, Body_Length : Stream_Element_Offset) is
      begin
         if Entry_Count < Max_Entries then
            Entry_Count := Entry_Count + 1;
            Entries (Entry_Count) := (Role, Id_At, Body_At,
                                      Stream_Element_Offset'Max (0, Stream_Element_Offset'Min (Body_Length, Last + 1 - Body_At)),
                                      Id_Length, Length_Field);
         end if;
      end Record_Chunk;

      --  The source description: the container, its own size field, the chunk count, then each chunk's role,
      --  identifier, length field and body, big-endian. Chunks other than the format, the audio and the RF64 size table are left out when all of
      --  them would not fit one metadata block.
      procedure Describe is
         function Size (Keep_Other : Boolean) return Long_Long_Integer is
            S : Long_Long_Integer := 11;
         begin
            for E of Entries (1 .. Entry_Count) loop
               if Keep_Other or else E.Role /= Other_Chunk then
                  S := S + 14 + Long_Long_Integer (E.Id_Length) + Long_Long_Integer (E.Body_Length);
               end if;
            end loop;
            return S;
         end Size;
         Keep_Other : constant Boolean := Size (True) <= Max_Source_Bytes;
         Length : constant Natural := Natural (Size (Keep_Other));
         Pos : Natural := 0;

         procedure Put (V : Long_Long_Integer; Bytes : Positive) is
         begin
            for K in reverse 0 .. Bytes - 1 loop
               Result.Source (Pos) := Byte (Shift_Right (Unsigned_64'Mod (V), 8 * K) and 255);
               Pos := Pos + 1;
            end loop;
         end Put;

         procedure Copy (From, Count : Stream_Element_Offset) is
         begin
            for K in 0 .. Count - 1 loop
               Result.Source (Pos) := Byte (Data (From + K));
               Pos := Pos + 1;
            end loop;
         end Copy;

         Kept : Natural := 0;
      begin
         Result.Foreign_Dropped := not Keep_Other;
         if Length > Max_Source_Bytes then
            return;
         end if;
         for E of Entries (1 .. Entry_Count) loop
            if Keep_Other or else E.Role /= Other_Chunk then
               Kept := Kept + 1;
            end if;
         end loop;
         Result.Source := new Byte_Array (0 .. Length - 1);
         Put (Long_Long_Integer (Kind), 1);
         Put (Size_Field, 8);
         Put (Long_Long_Integer (Kept), 2);
         for E of Entries (1 .. Entry_Count) loop
            if Keep_Other or else E.Role /= Other_Chunk then
               Put (Long_Long_Integer (E.Role), 1);
               Put (Long_Long_Integer (E.Id_Length), 1);
               Copy (E.Id_At, Stream_Element_Offset (E.Id_Length));
               Put (E.Length_Field, 8);
               Put (Long_Long_Integer (E.Body_Length), 4);
               Copy (E.Body_At, E.Body_Length);
            end if;
         end loop;
      end Describe;

      --  RIFF, RF64 and BW64: chunks with 32-bit little-endian lengths; RF64 and BW64 give the data length in ds64.
      procedure Read_Riff is
         Chunk : Stream_Element_Offset := 12;
         Data_Size_64 : Long_Long_Integer := -1;
      begin
         while Chunk + 8 <= Last + 1 loop
            declare
               Field : constant Long_Long_Integer := U32 (Chunk + 4);
               Length : Stream_Element_Offset := Stream_Element_Offset (Field);
               Start : constant Stream_Element_Offset := Chunk + 8;
            begin
               if Id (Chunk) = "ds64" and then Length >= 16 then
                  Data_Size_64 := U32 (Start + 8) + U32 (Start + 12) * 2**32;
                  Record_Chunk (Size_Table_Chunk, Chunk, 4, Field, Start, Length);
               elsif Id (Chunk) = "fmt " then
                  Wave_Format (Start, Length);
                  Record_Chunk (Format_Chunk, Chunk, 4, Field, Start, Length);
               elsif Id (Chunk) = "data" and then not Got_Audio then
                  if Length = 16#FFFF_FFFF# and then Data_Size_64 >= 0 then
                     Length := Stream_Element_Offset (Data_Size_64);
                  end if;
                  Samples (Start, Length, Big => False, Signed_Bytes => False);
                  Record_Chunk (Audio_Chunk, Chunk, 4, Field, Start, 0);
                  Got_Audio := True;
               else
                  Record_Chunk (Other_Chunk, Chunk, 4, Field, Start, Length);
               end if;
               Chunk := Start + Length + Length mod 2;
            end;
         end loop;
      end Read_Riff;

      --  Wave64: GUID chunk identifiers, 64-bit lengths that count the 24-byte chunk header, chunks aligned to 8.
      procedure Read_W64 is
         Chunk : Stream_Element_Offset := 40;
      begin
         while Chunk + 24 <= Last + 1 loop
            declare
               Field : constant Long_Long_Integer := U (Chunk + 16, 8);
               Length : constant Stream_Element_Offset :=
                 (if Field < 0 or else Field > Long_Long_Integer (Last + 1 - Chunk) then Last + 1 - Chunk
                  else Stream_Element_Offset (Field));
               Start : constant Stream_Element_Offset := Chunk + 24;
            begin
               if Length < 24 then
                  raise Constraint_Error with Name & ": bad Wave64 chunk length";
               elsif Is_Guid (Chunk, W64_Fmt) then
                  Wave_Format (Start, Length - 24);
                  Record_Chunk (Format_Chunk, Chunk, 16, Field, Start, Length - 24);
               elsif Is_Guid (Chunk, W64_Data) and then not Got_Audio then
                  Samples (Start, Length - 24, Big => False, Signed_Bytes => False);
                  Record_Chunk (Audio_Chunk, Chunk, 16, Field, Start, 0);
                  Got_Audio := True;
               else
                  Record_Chunk (Other_Chunk, Chunk, 16, Field, Start, Length - 24);
               end if;
               Chunk := (if Length >= Last + 1 - Chunk then Last + 1 else Chunk + (Length + 7) / 8 * 8);
            end;
         end loop;
      end Read_W64;

      --  AIFF and AIFF-C: big-endian chunks; the sample size may be any bit count, left-justified in whole bytes;
      --  AIFF-C names its sample coding: big-endian integers, little-endian (sowt) or 32-bit float.
      procedure Read_Aiff is
         Chunk : Stream_Element_Offset := 12;
         Little : Boolean := False;
      begin
         while Chunk + 8 <= Last + 1 loop
            declare
               Field : constant Long_Long_Integer := U (Chunk + 4, 4, Big => True);
               Length : constant Stream_Element_Offset := Stream_Element_Offset (Field);
               Start : constant Stream_Element_Offset := Chunk + 8;
               Skip : Stream_Element_Offset := Length;
            begin
               if Id (Chunk) = "COMM" then
                  declare
                     Bits : constant Natural := Natural (U (Start + 6, 2, Big => True));
                     Exponent : constant Long_Long_Integer := U (Start + 8, 2, Big => True) mod 2**15 - 16383;
                     Mantissa : constant Unsigned_64 := Unsigned_64 (U (Start + 10, 4, Big => True)) * 2**32
                                                        + Unsigned_64 (U (Start + 14, 4, Big => True));
                     Coding : constant String := (if Id (8) = "AIFC" and then Length >= 22 then Id (Start + 18) else "NONE");
                  begin
                     Result.Channels := Natural (U (Start, 2, Big => True));
                     Result.Rate := (if Exponent in 0 .. 63 then Natural (Shift_Right (Mantissa, Natural (63 - Exponent))) else 0);
                     Result.Is_Float := Coding in "fl32" | "FL32" | "fl64" | "FL64";
                     Little := Coding = "sowt";
                     Result.Depth := (if Coding in "fl64" | "FL64" then 64 elsif Result.Is_Float then 32 else (Bits + 7) / 8 * 8);
                     Result.Valid_Bits := (if Result.Is_Float then Result.Depth else Bits);
                     Result.Channel_Mask := 0;
                     if Coding not in "NONE" | "twos" | "sowt" | "fl32" | "FL32" | "fl64" | "FL64"
                       or else (Result.Is_Float and then Bits /= Result.Depth)
                       or else Result.Depth not in 8 | 16 | 24 | 32 | 64 or else Bits = 0
                       or else Result.Channels not in 1 .. Max_Channels
                     then
                        raise Constraint_Error with Name & ": only 1 to 32-bit integer and 32 or 64-bit float AIFF are read";
                     end if;
                     Have_Format := True;
                     Record_Chunk (Format_Chunk, Chunk, 4, Field, Start, Length);
                  end;
               elsif Id (Chunk) = "SSND" and then not Got_Audio then
                  declare
                     Offset : constant Stream_Element_Offset := Stream_Element_Offset (U (Start, 4, Big => True));
                     Sound : constant Stream_Element_Offset :=
                       (if Length < 8 + Offset or else Length > Last + 1 - Start then Last + 1 - Start else Length);
                  begin
                     Samples (Start + 8 + Offset, Sound - 8 - Offset, Big => not Little, Signed_Bytes => True);
                     Record_Chunk (Audio_Chunk, Chunk, 4, Field, Start, 8 + Offset);
                     Got_Audio := True;
                     Skip := Sound;
                  end;
               else
                  Record_Chunk (Other_Chunk, Chunk, 4, Field, Start, Length);
               end if;
               Chunk := Start + Skip + Skip mod 2;
            end;
         end loop;
      end Read_Aiff;
   begin
      Stream_IO.Open (File, Stream_IO.In_File, Name);
      Stream_IO.Read (File, Data.all, Last);
      Stream_IO.Close (File);
      if Id (0) in "RIFF" | "RF64" | "BW64" and then Id (8) = "WAVE" then
         Kind := (if Id (0) = "RIFF" then Riff_Wave elsif Id (0) = "RF64" then Rf64_Wave else Bw64_Wave);
         Size_Field := U32 (4);
         Read_Riff;
      elsif Is_Guid (0, W64_Riff) and then Is_Guid (24, W64_Wave) then
         Kind := Wave64;
         Size_Field := U (16, 8);
         Read_W64;
      elsif Id (0) = "FORM" and then Id (8) in "AIFF" | "AIFC" then
         Kind := (if Id (8) = "AIFF" then Aiff else Aiff_C);
         Size_Field := U (4, 4, Big => True);
         Read_Aiff;
      else
         raise Constraint_Error with Name & ": not a WAV, RF64, Wave64 or AIFF file";
      end if;
      if not Got_Audio then
         raise Constraint_Error with Name & ": no audio chunk";
      end if;
      Describe;
      Free (Data);
   end Read;

   procedure Write_Source (Name : String; Source : Byte_Array; Channels, Depth, Valid_Bits : Positive; Is_Float : Boolean;
                           Frames : Natural;
                           Sample : not null access function (C : Positive; F : Natural) return Long_Long_Integer;
                           Written : out Boolean) is
      type Item is record
         Role, Id_At, Id_Length, Body_At, Body_Length : Natural := 0;
         Length_Field : Long_Long_Integer := 0;
      end record;
      Items : array (1 .. 1024) of Item;
      Count : Natural := 0;
      First : constant Natural := Source'First;
      Pos : Natural := First + 11;
      Size_Field : Long_Long_Integer := 0;
      Kind : constant Natural := (if Source'Length >= 11 then Natural (Source (First)) else 0);
      Width : constant Positive := Depth / 8;
      Data_Bytes : constant Long_Long_Integer := Long_Long_Integer (Frames) * Long_Long_Integer (Channels * Width);
      Wave_Like : constant Boolean := Kind in Riff_Wave .. Wave64;
      Big, Signed_Bytes : Boolean := False;
      Format_Item, Formats, Audios : Natural := 0;

      --  Big-endian integer of Bytes bytes of Source at At_Byte, two's complement at 8 bytes; little-endian of a body.
      function Be (At_Byte, Bytes : Natural) return Long_Long_Integer is
         V : Unsigned_64 := 0;
      begin
         for K in 0 .. Bytes - 1 loop
            V := Shift_Left (V, 8) or Unsigned_64 (Source (At_Byte + K));
         end loop;
         return (if V > Unsigned_64 (Long_Long_Integer'Last) then Long_Long_Integer (V - 2**63) - Long_Long_Integer'Last - 1
                 else Long_Long_Integer (V));
      end Be;
      function Le (At_Byte, Bytes : Natural) return Long_Long_Integer is
         V : Long_Long_Integer := 0;
      begin
         for K in reverse 0 .. Bytes - 1 loop
            V := V * 256 + Long_Long_Integer (Source (At_Byte + K));
         end loop;
         return V;
      end Le;
      function Text (At_Byte : Natural) return String is
        (Character'Val (Natural (Source (At_Byte))) & Character'Val (Natural (Source (At_Byte + 1)))
         & Character'Val (Natural (Source (At_Byte + 2))) & Character'Val (Natural (Source (At_Byte + 3))));

      --  Bytes of an item's payload: the body, or for the audio chunk what precedes the samples and the samples.
      function Payload (I : Item) return Long_Long_Integer is
        (Long_Long_Integer (I.Body_Length) + (if I.Role = Audio_Chunk then Data_Bytes else 0));
      --  A size field as recorded when it holds a streaming writer's 0 or all ones, else as computed.
      function Kept (Recorded, Computed : Long_Long_Integer) return Long_Long_Integer is
        (if Recorded in 0 | 16#FFFF_FFFF# then Recorded else Computed);
      function On_Disk (I : Item) return Long_Long_Integer is
        (if Kind = Wave64 then 24 + (Payload (I) + 7) / 8 * 8 else 8 + Payload (I) + Payload (I) mod 2);

      Buffer : Stream_Element_Array (0 .. 65535);
      Fill : Stream_Element_Offset := 0;
      File : Stream_IO.File_Type;

      procedure Flush is
      begin
         Stream_IO.Write (File, Buffer (0 .. Fill - 1));
         Fill := 0;
      end Flush;

      --  Append Count bytes of V, least or most significant first.
      procedure Bytes (V : Long_Long_Integer; Count : Positive; Big_Endian : Boolean := False) is
         U : constant Unsigned_64 := Unsigned_64'Mod (V);
      begin
         if Fill + Stream_Element_Offset (Count) > Buffer'Length then
            Flush;
         end if;
         for K in 0 .. Count - 1 loop
            Buffer (Fill) := Stream_Element (Shift_Right (U, 8 * (if Big_Endian then Count - 1 - K else K)) and 255);
            Fill := Fill + 1;
         end loop;
      end Bytes;

      procedure Copy (At_Byte, Count : Natural) is
      begin
         for K in 0 .. Count - 1 loop
            Bytes (Long_Long_Integer (Source (At_Byte + K)), 1);
         end loop;
      end Copy;

      procedure Pad (Count : Long_Long_Integer) is
      begin
         for Unused in 1 .. Count loop
            Bytes (0, 1);
         end loop;
      end Pad;
   begin
      Written := False;
      if Kind not in Riff_Wave .. Aiff_C then
         return;
      end if;
      Size_Field := Be (First + 1, 8);
      Count := Natural (Be (First + 9, 2));
      if Count > Items'Length then
         return;
      end if;
      for I in 1 .. Count loop
         if Pos + 1 > Source'Last then
            return;
         end if;
         Items (I).Role := Natural (Source (Pos));
         Items (I).Id_Length := Natural (Source (Pos + 1));
         Pos := Pos + 2;
         if Items (I).Id_Length /= (if Kind = Wave64 then 16 else 4) or else Items (I).Role > Size_Table_Chunk
           or else Pos + Items (I).Id_Length + 12 - 1 > Source'Last
         then
            return;
         end if;
         Items (I).Id_At := Pos;
         Pos := Pos + Items (I).Id_Length;
         Items (I).Length_Field := Be (Pos, 8);
         if Be (Pos + 8, 4) > Long_Long_Integer (Source'Last + 1 - (Pos + 12)) then
            return;
         end if;
         Items (I).Body_Length := Natural (Be (Pos + 8, 4));
         Pos := Pos + 12;
         Items (I).Body_At := Pos;
         Pos := Pos + Items (I).Body_Length;
         if Items (I).Role = Format_Chunk then
            Formats := Formats + 1;
            Format_Item := I;
         elsif Items (I).Role = Audio_Chunk then
            Audios := Audios + 1;
         end if;
      end loop;
      if Pos /= Source'Last + 1 or else Formats /= 1 or else Audios /= 1 then
         return;
      end if;

      --  The format chunk must describe these samples.
      declare
         F : constant Item := Items (Format_Item);
         B : constant Natural := F.Body_At;
      begin
         if Wave_Like then
            if F.Body_Length < 16 or else Natural (Le (B + 2, 2)) /= Channels or else Natural (Le (B + 14, 2)) /= Depth then
               return;
            end if;
            declare
               Tag : constant Long_Long_Integer := Le (B, 2);
               Extensible : constant Boolean := Tag = 16#FFFE# and then F.Body_Length >= 26;
               Coding : constant Long_Long_Integer := (if Extensible then Le (B + 24, 2) else Tag);
               Valid : constant Natural :=
                 (if Extensible and then Le (B + 18, 2) in 1 .. Long_Long_Integer (Depth) then Natural (Le (B + 18, 2)) else Depth);
            begin
               if (Coding = 3) /= Is_Float or else Coding not in 1 | 3 or else Valid /= Valid_Bits then
                  return;
               end if;
            end;
         else
            declare
               Coding : constant String := (if Kind = Aiff_C and then F.Body_Length >= 22 then Text (B + 18) else "NONE");
            begin
               if F.Body_Length < 18 or else Natural (Be (B, 2)) /= Channels or else Be (B + 2, 4) not in 0 | Long_Long_Integer (Frames)
                 or else Natural (Be (B + 6, 2)) /= Valid_Bits or else (Coding in "fl32" | "FL32" | "fl64" | "FL64") /= Is_Float
                 or else (Coding in "fl64" | "FL64") /= (Depth = 64)
                 or else Coding not in "NONE" | "twos" | "sowt" | "fl32" | "FL32" | "fl64" | "FL64"
               then
                  return;
               end if;
               Big := Coding /= "sowt";
               Signed_Bytes := True;
            end;
         end if;
      end;

      declare
         Chunks_Bytes : Long_Long_Integer := 0;
      begin
         for I of Items (1 .. Count) loop
            Chunks_Bytes := Chunks_Bytes + On_Disk (I);
         end loop;
         if (Kind = Riff_Wave or else Kind in Aiff | Aiff_C) and then 4 + Chunks_Bytes > 16#FFFF_FFFF# then
            return;
         end if;
         Stream_IO.Create (File, Stream_IO.Out_File, Name);
         case Kind is
            when Riff_Wave | Rf64_Wave | Bw64_Wave =>
               for Ch of String'(if Kind = Riff_Wave then "RIFF" elsif Kind = Rf64_Wave then "RF64" else "BW64") loop
                  Bytes (Character'Pos (Ch), 1);
               end loop;
               Bytes ((if Kind = Riff_Wave then Kept (Size_Field, 4 + Chunks_Bytes) else 16#FFFF_FFFF#), 4);
               for Ch of String'("WAVE") loop
                  Bytes (Character'Pos (Ch), 1);
               end loop;
            when Wave64 =>
               for B of W64_Riff loop
                  Bytes (Long_Long_Integer (B), 1);
               end loop;
               Bytes ((if Size_Field in 0 | -1 then Size_Field else 40 + Chunks_Bytes), 8);
               for B of W64_Wave loop
                  Bytes (Long_Long_Integer (B), 1);
               end loop;
            when others =>
               for Ch of String'("FORM") loop
                  Bytes (Character'Pos (Ch), 1);
               end loop;
               Bytes (Kept (Size_Field, 4 + Chunks_Bytes), 4, Big_Endian => True);
               for Ch of String'(if Kind = Aiff then "AIFF" else "AIFC") loop
                  Bytes (Character'Pos (Ch), 1);
               end loop;
         end case;
         for I of Items (1 .. Count) loop
            declare
               Length : constant Long_Long_Integer := Payload (I);
            begin
               Copy (I.Id_At, I.Id_Length);
               if Kind = Wave64 then
                  Bytes ((if I.Role = Audio_Chunk and then I.Length_Field in 0 | -1 | Long_Long_Integer'Last then I.Length_Field
                          else 24 + Length), 8);
               elsif Kind in Aiff | Aiff_C then
                  Bytes ((if I.Role = Audio_Chunk then Kept (I.Length_Field, Length) else Length), 4, Big_Endian => True);
               elsif I.Role = Audio_Chunk then
                  Bytes ((if Length > 16#FFFF_FFFF# then 16#FFFF_FFFF# else Kept (I.Length_Field, Length)), 4);
               else
                  Bytes (Length, 4);
               end if;
               if I.Role = Size_Table_Chunk and then I.Body_Length >= 24 then
                  Bytes (4 + Chunks_Bytes, 8);
                  Bytes (Data_Bytes, 8);
                  Bytes (Long_Long_Integer (Frames), 8);
                  Copy (I.Body_At + 24, I.Body_Length - 24);
               else
                  Copy (I.Body_At, I.Body_Length);
               end if;
               if I.Role = Audio_Chunk then
                  for F in 0 .. Frames - 1 loop
                     for C in 1 .. Channels loop
                        declare
                           V : constant Long_Long_Integer := Sample (C, F);
                        begin
                           if Width = 8 then
                              declare
                                 D : constant Unsigned_64 := Float_Bits.Widen (Unsigned_32 (if V >= 0 then V else 2**31 - 1 - V));
                              begin
                                 for K in 0 .. 7 loop
                                    Bytes (Long_Long_Integer (Shift_Right (D, 8 * (if Big then 7 - K else K)) and 255), 1);
                                 end loop;
                              end;
                           else
                              Bytes ((if Is_Float then (if V >= 0 then V else 2**31 - 1 - V)
                                      elsif Width = 1 and then not Signed_Bytes then V + 128 else V), Width, Big_Endian => Big);
                           end if;
                        end;
                     end loop;
                  end loop;
               end if;
               Pad (On_Disk (I) - (if Kind = Wave64 then 24 else 8) - Length);
            end;
         end loop;
         Flush;
         Stream_IO.Close (File);
         Written := True;
      end;
   end Write_Source;

   procedure Write (Name : String; Channels, Rate, Depth, Valid_Bits : Positive; Channel_Mask : Long_Long_Integer;
                    Is_Float : Boolean; Frames : Natural;
                    Sample : not null access function (C : Positive; F : Natural) return Long_Long_Integer) is
      Width : constant Positive := Depth / 8;
      Extensible : constant Boolean := Channels > 2 or else Depth > 16 or else Valid_Bits /= Depth or else Channel_Mask /= 0;
      Format_Bytes : constant Natural := (if Extensible then 40 else 16);
      Chunks : constant Natural := (if Is_Float then 3 else 2);
      Description : Byte_Array (0 .. 11 + 14 + 4 + Format_Bytes + (if Is_Float then 14 + 4 + 4 else 0) + 14 + 4 - 1);
      Pos : Natural := 0;
      Written : Boolean;
      Subformat_Tail : constant array (1 .. 8) of Long_Long_Integer := [16#80#, 0, 0, 16#AA#, 0, 16#38#, 16#9B#, 16#71#];

      procedure Put (V : Long_Long_Integer; Count : Positive; Big_Endian : Boolean := True) is
      begin
         for K in 0 .. Count - 1 loop
            Description (Pos) := Byte (V / 2**(8 * (if Big_Endian then Count - 1 - K else K)) mod 256);
            Pos := Pos + 1;
         end loop;
      end Put;

      procedure Put_Text (S : String) is
      begin
         for Ch of S loop
            Put (Character'Pos (Ch), 1);
         end loop;
      end Put_Text;
   begin
      --  Size fields recorded as 1, which is no streaming writer's value, so the writer computes every one.
      Put (Riff_Wave, 1);
      Put (1, 8);
      Put (Long_Long_Integer (Chunks), 2);
      Put (Format_Chunk, 1);
      Put (4, 1);
      Put_Text ("fmt ");
      Put (Long_Long_Integer (Format_Bytes), 8);
      Put (Long_Long_Integer (Format_Bytes), 4);
      Put ((if Extensible then 16#FFFE# elsif Is_Float then 3 else 1), 2, Big_Endian => False);
      Put (Long_Long_Integer (Channels), 2, Big_Endian => False);
      Put (Long_Long_Integer (Rate), 4, Big_Endian => False);
      Put (Long_Long_Integer (Rate) * Long_Long_Integer (Channels * Width), 4, Big_Endian => False);
      Put (Long_Long_Integer (Channels * Width), 2, Big_Endian => False);
      Put (Long_Long_Integer (Depth), 2, Big_Endian => False);
      if Extensible then
         Put (22, 2, Big_Endian => False);
         Put (Long_Long_Integer (Valid_Bits), 2, Big_Endian => False);
         Put (Channel_Mask, 4, Big_Endian => False);
         Put ((if Is_Float then 3 else 1), 4, Big_Endian => False);
         Put (0, 2, Big_Endian => False);
         Put (16#0010#, 2, Big_Endian => False);
         for B of Subformat_Tail loop
            Put (B, 1);
         end loop;
      end if;
      if Is_Float then
         Put (Other_Chunk, 1);
         Put (4, 1);
         Put_Text ("fact");
         Put (4, 8);
         Put (4, 4);
         Put (Long_Long_Integer (Frames), 4, Big_Endian => False);
      end if;
      Put (Audio_Chunk, 1);
      Put (4, 1);
      Put_Text ("data");
      Put (1, 8);
      Put (0, 4);
      Write_Source (Name, Description, Channels, Depth, Valid_Bits, Is_Float, Frames, Sample, Written);
      if not Written then
         raise Constraint_Error with Name & ": too large for a WAV file";
      end if;
   end Write;

end Wav_Files;
