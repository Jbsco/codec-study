with Ada.Unchecked_Deallocation;
with System.Multiprocessors;
with Audio_Digest;
with Bit_Streams; use Bit_Streams;
with Huffman_Codes; use Huffman_Codes;
with Stream_Format; use Stream_Format;
with Stream_Reading; use Stream_Reading;
with Stream_Writing; use Stream_Writing;
with Wav_Files;

package body Codec_Api is

   use type System.Address;

   Ok : constant := 0;
   Damaged : constant := 1;
   Refused : constant := 2;
   Unsupported : constant := 3;
   Bad_Argument : constant := -1;
   Failed : constant := -2;

   type Int32_Array is array (Integer_64 range <>) of Integer_32;

   procedure Free is new Ada.Unchecked_Deallocation (Byte_Array, Byte_Array_Access);
   procedure Free is new Ada.Unchecked_Deallocation (Value_Array, Value_Array_Access);

   function Api_Version_Of return int is (Api_Version);

   function Format_Version_Of return int is (Stream_Format.Version);

   function Encode_Bound (Frames : Integer_64; Channels : Integer_32) return Integer_64 is
     (if Frames not in 0 .. Integer_64 (Natural'Last) or else Channels not in 1 .. Integer_32 (Max_Channels) then Bad_Argument
      else 4096 + (Frames + 4095) / 4096 * (4096 + Integer_64 (Channels) * 20_800));

   function Encode (Samples : System.Address; Audio : access constant Info; Level, Threads : Integer_32;
                    Stream : System.Address; Capacity : Integer_64) return Integer_64 is
   begin
      if Samples = System.Null_Address or else Audio = null or else Stream = System.Null_Address
        or else Audio.Channels not in 1 .. Integer_32 (Max_Channels) or else Audio.Depth not in 8 | 16 | 24 | 32
        or else Audio.Valid_Bits not in 1 .. Audio.Depth or else Audio.Frames not in 0 .. Integer_64 (Natural'Last)
        or else Audio.Rate < 0 or else Audio.Is_Float /= 0 or else Level not in 0 .. 5 or else Threads not in 0 .. 1024
      then
         return Bad_Argument;
      end if;
      declare
         Channels : constant Integer_64 := Integer_64 (Audio.Channels);
         Frames : constant Natural := Natural (Audio.Frames);
         X : Int32_Array (0 .. Integer_64 (Frames) * Channels - 1) with Import, Address => Samples;
         Half : constant Integer_64 := 2**Natural (Audio.Depth - 1);
         Input : Wav_Files.Audio;
         Opt : Options;
         Coded : Byte_Array_Access;
         Length : Natural;
         Stats : Statistics;
      begin
         for V of X loop
            if Integer_64 (V) < -Half or else Integer_64 (V) >= Half then
               return Bad_Argument;
            end if;
         end loop;
         Input.Channels := Natural (Audio.Channels);
         Input.Rate := Natural (Audio.Rate);
         Input.Depth := Natural (Audio.Depth);
         Input.Valid_Bits := Natural (Audio.Valid_Bits);
         Input.Channel_Mask := Long_Long_Integer (Audio.Channel_Mask);
         Input.Frames := Frames;
         for C in 1 .. Input.Channels loop
            Input.Samples (C) := new Value_Array (0 .. Frames - 1);
            for F in 0 .. Frames - 1 loop
               Input.Samples (C) (F) := Long_Long_Integer (X (Integer_64 (F) * Channels + Integer_64 (C - 1)));
            end loop;
         end loop;
         Opt.Level := Natural (Level);
         Opt.Threads := (if Threads = 0 then Positive (System.Multiprocessors.Number_Of_CPUs) else Positive (Threads));
         Stream_Writing.Encode (Input, Opt, Coded, Length, Stats);
         for C in 1 .. Input.Channels loop
            Free (Input.Samples (C));
         end loop;
         Release (Stats);
         if Integer_64 (Length) > Capacity then
            Free (Coded);
            return Bad_Argument;
         end if;
         declare
            Out_Bytes : Byte_Array (0 .. Length - 1) with Import, Address => Stream;
         begin
            Out_Bytes := Coded (0 .. Length - 1);
         end;
         Free (Coded);
         return Integer_64 (Length);
      end;
   exception
      when others =>
         return Failed;
   end Encode;

   --  The stream at Stream as an array indexed from 0, as the reader takes it.
   function Copy (Stream : System.Address; Length : Integer_64) return Byte_Array_Access is
      Given : constant Byte_Array (0 .. Natural (Length) - 1) with Import, Address => Stream;
   begin
      return new Byte_Array'(Given);
   end Copy;

   function Read_Info (Stream : System.Address; Length : Integer_64; Audio : access Info) return int is
   begin
      if Stream = System.Null_Address or else Audio = null or else Length not in 0 .. Integer_64 (Natural'Last) then
         return Bad_Argument;
      end if;
      declare
         S : Byte_Array_Access := Copy (Stream, Length);
         H : Header;
      begin
         Read_Header (S.all, H);
         Free (S);
         if not H.Ok then
            Release (H);
            return Refused;
         end if;
         Audio.all := (Channels => Integer_32 (H.Channels), Rate => Integer_32 (H.Rate), Depth => Integer_32 (H.Depth),
                       Valid_Bits => Integer_32 (H.Valid_Bits), Frames => Integer_64 (H.Frames),
                       Channel_Mask => Unsigned_32 (H.Channel_Mask), Is_Float => (if H.Is_Float then 1 else 0),
                       Audio_Md5 => [others => 0]);
         for I in Audio.Audio_Md5'Range loop
            Audio.Audio_Md5 (I) := Unsigned_8 (H.Audio_Md5 (H.Audio_Md5'First + I));
         end loop;
         Release (H);
         return Ok;
      end;
   exception
      when others =>
         return Failed;
   end Read_Info;

   function Decode (Stream : System.Address; Length : Integer_64; Samples : System.Address; Capacity_Frames : Integer_64;
                    Report : access Damage_Report) return int is
   begin
      if Stream = System.Null_Address or else Samples = System.Null_Address or else Report = null
        or else Length not in 0 .. Integer_64 (Natural'Last) or else Capacity_Frames < 0
      then
         return Bad_Argument;
      end if;
      declare
         S : constant Byte_Array_Access := Copy (Stream, Length);
         H : Header;
      begin
         Read_Header (S.all, H);
         if not H.Ok then
            declare
               Unused : Byte_Array_Access := S;
            begin
               Free (Unused);
            end;
            Release (H);
            return Refused;
         end if;
         if H.Is_Float or else Integer_64 (H.Frames) > Integer_64'Min (Capacity_Frames, Integer_64 (Natural'Last)) then
            declare
               Unused : Byte_Array_Access := S;
            begin
               Free (Unused);
            end;
            Release (H);
            return (if H.Is_Float then Unsupported else Bad_Argument);
         end if;
         declare
            Channels : constant Integer_64 := Integer_64 (H.Channels);
            X : Int32_Array (0 .. Integer_64 (H.Frames) * Channels - 1) with Import, Address => Samples;
            W : Walker;
            Check : Audio_Digest.Hasher;
            Got : Audio_Digest.Digest;
            D : Damage;
            Recorded : constant Boolean := H.Audio_Md5 /= Audio_Digest.Not_Recorded;
            Unused : Byte_Array_Access := S;
         begin
            Start (W, S, H);
            Audio_Digest.Start (Check, H.Depth, H.Valid_Bits, H.Is_Float);
            for F in 0 .. H.Frames - 1 loop
               Advance (W, F);
               for C in 1 .. H.Channels loop
                  declare
                     V : constant Long_Long_Integer := Value (W, C, F);
                  begin
                     Audio_Digest.Add (Check, V);
                     X (Integer_64 (F) * Channels + Integer_64 (C - 1)) := Integer_32 (V);
                  end;
               end loop;
            end loop;
            Audio_Digest.Finish (Check, Got);
            D := Stream_Reading.Report (W);
            Stop (W);
            Free (Unused);
            Report.all := (Lost_Frames => Integer_64 (D.Lost_Frames), Bad_Groups => Integer_32 (D.Bad_Groups),
                           Bad_Block_Crcs => Integer_32 (D.Bad_Crcs), Blocks_Ok => (if D.Blocks_Ok then 1 else 0),
                           Audio_Md5 => (if not Recorded then 0 elsif Got = H.Audio_Md5 then 1 else 2));
            Release (H);
            return (if D.Complete and then D.Blocks_Ok and then D.Bad_Crcs = 0 and then (not Recorded or else Got = H.Audio_Md5)
                    then Ok else Damaged);
         end;
      end;
   exception
      when others =>
         return Failed;
   end Decode;

end Codec_Api;
