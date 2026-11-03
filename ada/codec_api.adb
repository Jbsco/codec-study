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
   type Pattern_Array is array (Integer_64 range <>) of Unsigned_32;

   procedure Free is new Ada.Unchecked_Deallocation (Byte_Array, Byte_Array_Access);
   procedure Free is new Ada.Unchecked_Deallocation (Value_Array, Value_Array_Access);

   function Api_Version_Of return int is (Api_Version);

   function Format_Version_Of return int is (Stream_Format.Version);

   function Encode_Bound (Frames : Integer_64; Channels : Integer_32) return Integer_64 is
     (if Frames not in 0 .. Integer_64 (Natural'Last) or else Channels not in 1 .. Integer_32 (Max_Channels) then Bad_Argument
      else 4096 + (Frames + 4095) / 4096 * (4096 + Integer_64 (Channels) * 20_800));

   --  Code the audio Audio describes, taking interleaved sample I from Value, as integers or as float bit patterns.
   function Encode_With (Audio : Info; Is_Float : Boolean; Value : not null access function (I : Integer_64) return Long_Long_Integer;
                         Level, Threads : Integer_32; Stream : System.Address; Capacity : Integer_64) return Integer_64 is
      Frames : constant Natural := Natural (Audio.Frames);
      Channels : constant Integer_64 := Integer_64 (Audio.Channels);
      Input : Wav_Files.Audio;
      Opt : Options;
      Coded : Byte_Array_Access;
      Length : Natural;
      Stats : Statistics;
   begin
      Input.Channels := Natural (Audio.Channels);
      Input.Rate := Natural (Audio.Rate);
      Input.Depth := Natural (Audio.Depth);
      Input.Valid_Bits := Natural (Audio.Valid_Bits);
      Input.Is_Float := Is_Float;
      Input.Channel_Mask := Long_Long_Integer (Audio.Channel_Mask);
      Input.Frames := Frames;
      for C in 1 .. Input.Channels loop
         Input.Samples (C) := new Value_Array (0 .. Frames - 1);
         for F in 0 .. Frames - 1 loop
            Input.Samples (C) (F) := Value (Integer_64 (F) * Channels + Integer_64 (C - 1));
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
   end Encode_With;

   --  The checks every encode shares: the pointers, the channels, frames and rate, the level and the threads.
   function Arguments_Ok (Samples : System.Address; Audio : access constant Info; Level, Threads : Integer_32;
                          Stream : System.Address) return Boolean is
     (Samples /= System.Null_Address and then Audio /= null and then Stream /= System.Null_Address
      and then Audio.Channels in 1 .. Integer_32 (Max_Channels) and then Audio.Frames in 0 .. Integer_64 (Natural'Last)
      and then Audio.Rate >= 0 and then Level in 0 .. 5 and then Threads in 0 .. 1024);

   function Encode (Samples : System.Address; Audio : access constant Info; Level, Threads : Integer_32;
                    Stream : System.Address; Capacity : Integer_64) return Integer_64 is
   begin
      if not Arguments_Ok (Samples, Audio, Level, Threads, Stream) or else Audio.Depth not in 8 | 16 | 24 | 32
        or else Audio.Valid_Bits not in 1 .. Audio.Depth or else Audio.Is_Float /= 0
      then
         return Bad_Argument;
      end if;
      declare
         X : Int32_Array (0 .. Audio.Frames * Integer_64 (Audio.Channels) - 1) with Import, Address => Samples;
         Half : constant Integer_64 := 2**Natural (Audio.Depth - 1);
         function Value (I : Integer_64) return Long_Long_Integer is (Long_Long_Integer (X (I)));
      begin
         for V of X loop
            if Integer_64 (V) < -Half or else Integer_64 (V) >= Half then
               return Bad_Argument;
            end if;
         end loop;
         return Encode_With (Audio.all, False, Value'Access, Level, Threads, Stream, Capacity);
      end;
   exception
      when others =>
         return Failed;
   end Encode;

   function Encode_Float (Samples : System.Address; Audio : access constant Info; Level, Threads : Integer_32;
                          Stream : System.Address; Capacity : Integer_64) return Integer_64 is
   begin
      if not Arguments_Ok (Samples, Audio, Level, Threads, Stream) or else Audio.Depth /= 32 or else Audio.Valid_Bits /= 32 then
         return Bad_Argument;
      end if;
      declare
         X : Pattern_Array (0 .. Audio.Frames * Integer_64 (Audio.Channels) - 1) with Import, Address => Samples;
         function Value (I : Integer_64) return Long_Long_Integer is (Ordered (Long_Long_Integer (X (I))));
      begin
         return Encode_With (Audio.all, True, Value'Access, Level, Threads, Stream, Capacity);
      end;
   exception
      when others =>
         return Failed;
   end Encode_Float;

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

   --  Decode a stream of the sample kind Is_Float names, handing interleaved sample I to Store as the integer, or as
   --  the order-keeping integer of a float's bit pattern.
   function Decode_With (Stream : System.Address; Length : Integer_64; Is_Float : Boolean;
                         Store : not null access procedure (I : Integer_64; V : Long_Long_Integer);
                         Capacity_Frames : Integer_64; Report : access Damage_Report) return int is
      S : Byte_Array_Access := Copy (Stream, Length);
      H : Header;
   begin
      Read_Header (S.all, H);
      if not H.Ok or else H.Is_Float /= Is_Float or else Integer_64 (H.Frames) > Capacity_Frames then
         Free (S);
         Release (H);
         return (if not H.Ok then Refused elsif H.Is_Float /= Is_Float then Unsupported else Bad_Argument);
      end if;
      declare
         Channels : constant Integer_64 := Integer_64 (H.Channels);
         W : Walker;
         Check : Audio_Digest.Hasher;
         Got : Audio_Digest.Digest;
         D : Damage;
         Recorded : constant Boolean := H.Audio_Md5 /= Audio_Digest.Not_Recorded;
         Matches : Boolean;
      begin
         Start (W, S, H);
         Audio_Digest.Start (Check, H.Depth, H.Valid_Bits, H.Is_Float);
         for F in 0 .. H.Frames - 1 loop
            Advance (W, F);
            for C in 1 .. H.Channels loop
               declare
                  V : Long_Long_Integer := Value (W, C, F);
               begin
                  if H.Is_Float and then H.Modes (C) = 1 then
                     V := From_Integer (V, H.Scales (C));
                  end if;
                  Audio_Digest.Add (Check, V);
                  Store (Integer_64 (F) * Channels + Integer_64 (C - 1), V);
               end;
            end loop;
         end loop;
         Audio_Digest.Finish (Check, Got);
         D := Stream_Reading.Report (W);
         Stop (W);
         Free (S);
         Matches := Got = H.Audio_Md5;
         Report.all := (Lost_Frames => Integer_64 (D.Lost_Frames), Bad_Groups => Integer_32 (D.Bad_Groups),
                        Bad_Block_Crcs => Integer_32 (D.Bad_Crcs), Blocks_Ok => (if D.Blocks_Ok then 1 else 0),
                        Audio_Md5 => (if not Recorded then 0 elsif Matches then 1 else 2));
         Release (H);
         return (if D.Complete and then D.Blocks_Ok and then D.Bad_Crcs = 0 and then (not Recorded or else Matches) then Ok
                 else Damaged);
      end;
   end Decode_With;

   --  The checks every decode shares, and the frames a caller's buffer may be taken to hold.
   function Decode_Arguments_Ok (Stream, Samples : System.Address; Length, Capacity_Frames : Integer_64;
                                 Report : access Damage_Report) return Boolean is
     (Stream /= System.Null_Address and then Samples /= System.Null_Address and then Report /= null
      and then Length in 0 .. Integer_64 (Natural'Last) and then Capacity_Frames >= 0);

   function Frames_Held (Capacity_Frames : Integer_64) return Integer_64 is
     (Integer_64'Min (Capacity_Frames, Integer_64 (Natural'Last)));

   function Decode (Stream : System.Address; Length : Integer_64; Samples : System.Address; Capacity_Frames : Integer_64;
                    Report : access Damage_Report) return int is
   begin
      if not Decode_Arguments_Ok (Stream, Samples, Length, Capacity_Frames, Report) then
         return Bad_Argument;
      end if;
      declare
         X : Int32_Array (0 .. Frames_Held (Capacity_Frames) * Integer_64 (Max_Channels) - 1) with Import, Address => Samples;
         procedure Store (I : Integer_64; V : Long_Long_Integer) is
         begin
            X (I) := Integer_32 (V);
         end Store;
      begin
         return Decode_With (Stream, Length, False, Store'Access, Frames_Held (Capacity_Frames), Report);
      end;
   exception
      when others =>
         return Failed;
   end Decode;

   function Decode_Float (Stream : System.Address; Length : Integer_64; Samples : System.Address; Capacity_Frames : Integer_64;
                          Report : access Damage_Report) return int is
   begin
      if not Decode_Arguments_Ok (Stream, Samples, Length, Capacity_Frames, Report) then
         return Bad_Argument;
      end if;
      declare
         X : Pattern_Array (0 .. Frames_Held (Capacity_Frames) * Integer_64 (Max_Channels) - 1) with Import, Address => Samples;
         procedure Store (I : Integer_64; V : Long_Long_Integer) is
         begin
            X (I) := Unsigned_32 (Bits_Of (V));
         end Store;
      begin
         return Decode_With (Stream, Length, True, Store'Access, Frames_Held (Capacity_Frames), Report);
      end;
   exception
      when others =>
         return Failed;
   end Decode_Float;

   --  Decode frames First .. First + Count - 1 of a stream of the sample kind Is_Float names, from the seek point at or
   --  before First, handing interleaved sample I of the range to Store.
   function Decode_Range_With (Stream : System.Address; Length : Integer_64; Is_Float : Boolean; First, Count : Integer_64;
                               Store : not null access procedure (I : Integer_64; V : Long_Long_Integer);
                               Report : access Damage_Report) return int is
      S : Byte_Array_Access := Copy (Stream, Length);
      H : Header;
   begin
      Read_Header (S.all, H);
      if not H.Ok or else H.Is_Float /= Is_Float or else First < 0 or else Count < 0
        or else First + Count > Integer_64 (H.Frames)
      then
         Free (S);
         Release (H);
         return (if not H.Ok then Refused elsif H.Is_Float /= Is_Float then Unsupported else Bad_Argument);
      end if;
      declare
         Channels : constant Integer_64 := Integer_64 (H.Channels);
         W : Walker;
         D : Damage;
      begin
         Start (W, S, H);
         if Count > 0 then
            Seek (W, Natural (First));
         end if;
         for F in Natural (First) .. Natural (First + Count) - 1 loop
            Advance (W, F);
            for C in 1 .. H.Channels loop
               declare
                  V : Long_Long_Integer := Value (W, C, F);
               begin
                  if H.Is_Float and then H.Modes (C) = 1 then
                     V := From_Integer (V, H.Scales (C));
                  end if;
                  Store ((Integer_64 (F) - First) * Channels + Integer_64 (C - 1), V);
               end;
            end loop;
         end loop;
         D := Stream_Reading.Report (W);
         Stop (W);
         Free (S);
         Report.all := (Lost_Frames => Integer_64 (D.Lost_Frames), Bad_Groups => Integer_32 (D.Bad_Groups),
                        Bad_Block_Crcs => Integer_32 (D.Bad_Crcs), Blocks_Ok => (if D.Blocks_Ok then 1 else 0),
                        Audio_Md5 => 0);
         Release (H);
         return (if D.Bad_Groups = 0 and then D.Lost_Frames = 0 and then D.Bad_Crcs = 0 and then D.Blocks_Ok then Ok
                 else Damaged);
      end;
   end Decode_Range_With;

   function Range_Arguments_Ok (Stream, Samples : System.Address; Length, Count : Integer_64;
                                Report : access Damage_Report) return Boolean is
     (Stream /= System.Null_Address and then Samples /= System.Null_Address and then Report /= null
      and then Length in 0 .. Integer_64 (Natural'Last) and then Count in 0 .. Integer_64 (Natural'Last));

   function Decode_Range (Stream : System.Address; Length, First, Count : Integer_64; Samples : System.Address;
                          Report : access Damage_Report) return int is
   begin
      if not Range_Arguments_Ok (Stream, Samples, Length, Count, Report) then
         return Bad_Argument;
      end if;
      declare
         X : Int32_Array (0 .. Count * Integer_64 (Max_Channels) - 1) with Import, Address => Samples;
         procedure Store (I : Integer_64; V : Long_Long_Integer) is
         begin
            X (I) := Integer_32 (V);
         end Store;
      begin
         return Decode_Range_With (Stream, Length, False, First, Count, Store'Access, Report);
      end;
   exception
      when others =>
         return Failed;
   end Decode_Range;

   function Decode_Range_Float (Stream : System.Address; Length, First, Count : Integer_64; Samples : System.Address;
                                Report : access Damage_Report) return int is
   begin
      if not Range_Arguments_Ok (Stream, Samples, Length, Count, Report) then
         return Bad_Argument;
      end if;
      declare
         X : Pattern_Array (0 .. Count * Integer_64 (Max_Channels) - 1) with Import, Address => Samples;
         procedure Store (I : Integer_64; V : Long_Long_Integer) is
         begin
            X (I) := Unsigned_32 (Bits_Of (V));
         end Store;
      begin
         return Decode_Range_With (Stream, Length, True, First, Count, Store'Access, Report);
      end;
   exception
      when others =>
         return Failed;
   end Decode_Range_Float;

end Codec_Api;
