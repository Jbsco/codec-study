--  Code a WAV file with the block codec, decode it again and compare every sample. Prints the size, a hash of
--  the coded stream, the wall time of each step, and which block coding was chosen how often.
--  Usage: codec_main <file.wav> [level 0 to 5, 4 when left out] [--stream <out.bin>, to write the coded stream]
--  [--features <out.tsv>, to write each group's features and whether the search split its root]
--  [--tag <key=value>, repeatable] [--seek-every <seconds>, 10 when left out, 0 for one segment] [--independent,
--  every group its own segment] [--seek <frame>, to decode from that frame's seek point alone after the full
--  decode] [--flip <group> <byte>, to flip a bit of the coded stream before decoding] [--no-pairs, to code every
--  channel alone]
with Ada.Command_Line;
with Ada.Direct_IO;
with Ada.Real_Time;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Audio_Digest;
with Interfaces; use Interfaces;
with Bit_Streams; use Bit_Streams;
with Stream_Format; use Stream_Format;
with Stream_Reading;
with Stream_Writing; use Stream_Writing;
with Wav_Files; use type Wav_Files.Source_Access;

procedure Codec_Main is
   use Ada.Text_IO;
   use type Ada.Real_Time.Time;

   package Real_Text is new Float_IO (Long_Float);

   procedure Put_Real (Value : Long_Float; Aft : Natural := 2) is
   begin
      Real_Text.Put (Value, Fore => 4, Aft => Aft, Exp => 0);
   end Put_Real;

   Mode_Names : constant array (0 .. 3) of String (1 .. 10) := ["left/right", "left/side ", "side/right", "mid/side  "];

   package Byte_IO is new Ada.Direct_IO (Byte);
   Features : aliased Ada.Text_IO.File_Type;

   --  The option's index on the command line, 0 when absent.
   function Option (Name : String) return Natural is
   begin
      for I in 2 .. Ada.Command_Line.Argument_Count loop
         if Ada.Command_Line.Argument (I) = Name then
            return I;
         end if;
      end loop;
      return 0;
   end Option;

   function Option_Value (Name : String; Default : Natural) return Natural is
     (if Option (Name) > 0 and then Option (Name) < Ada.Command_Line.Argument_Count
      then Natural'Value (Ada.Command_Line.Argument (Option (Name) + 1)) else Default);

   --  Write Data to the file named after "--stream" on the command line, when present.
   procedure Write_Stream (Data : Byte_Array) is
      File : Byte_IO.File_Type;
   begin
      if Option ("--stream") > 0 then
         Byte_IO.Create (File, Byte_IO.Out_File, Ada.Command_Line.Argument (Option ("--stream") + 1));
         for B of Data loop
            Byte_IO.Write (File, B);
         end loop;
         Byte_IO.Close (File);
      end if;
   end Write_Stream;


   Input : Wav_Files.Audio;
   Opt : Options;
begin
   Wav_Files.Read (Ada.Command_Line.Argument (1), 3600, Input);
   Opt.Level := (if Ada.Command_Line.Argument_Count >= 2
                   and then (Ada.Command_Line.Argument (2)'Length < 2 or else Ada.Command_Line.Argument (2) (1 .. 2) /= "--")
                 then Natural'Value (Ada.Command_Line.Argument (2)) else 4);
   Opt.Independent := Option ("--independent") > 0;
   Opt.Seek_Every := Option_Value ("--seek-every", Default_Seek_Every (Opt.Level));
   Opt.Pairs := Option ("--no-pairs") = 0;
   for I in 2 .. Ada.Command_Line.Argument_Count - 1 loop
      if Ada.Command_Line.Argument (I) = "--tag" then
         Opt.Tag_Count := Opt.Tag_Count + 1;
         Opt.Tags (Opt.Tag_Count) := Ada.Strings.Unbounded.To_Unbounded_String (Ada.Command_Line.Argument (I + 1));
      end if;
   end loop;
   if Option ("--features") > 0 then
      Ada.Text_IO.Create (Features, Ada.Text_IO.Out_File, Ada.Command_Line.Argument (Option ("--features") + 1));
      Opt.Features := Features'Unchecked_Access;
   end if;
   declare
      Level : constant Natural := Opt.Level;
      Frames : constant Natural := Input.Frames;
      Channels : constant Natural := Input.Channels;
      Rate : constant Natural := Input.Rate;
      Pairs : constant Natural := Channels / 2;
      Independent : constant Boolean := Opt.Independent;
      Start : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      Encoded : Ada.Real_Time.Time;
      Same : Boolean := True;
      Hash : Unsigned_64 := 14695981039346656037;
      Stream : Byte_Array_Access;
      Length : Natural;
      Stats : Statistics;
      Kinds : Kind_Counts renames Stats.Kinds;
      Side : Side_Counts renames Stats.Side;
      Stereo : Natural_Array renames Stats.Stereo;
      Leaves : Natural_Array renames Stats.Leaves;
      Header_Length : Natural renames Stats.Header_Length;
      Groups : Natural renames Stats.Groups;
      Blocks : Natural renames Stats.Blocks;
      Framing : Natural renames Stats.Framing;
      Segment_Span : Natural renames Stats.Segment_Span;
      Mode : Channel_Naturals renames Stats.Modes;
      Scale : Channel_Naturals renames Stats.Scales;
      Audio_Md5 : Audio_Digest.Digest renames Stats.Audio_Md5;

      --  The input sample as the decoder must return it: the integer, or the float's integer scaled back.
      function Original (C : Positive; I : Natural) return Long_Long_Integer is
        (if Mode (C) = 1 then From_Integer (Input.Samples (C) (I), Scale (C)) else Input.Samples (C) (I));
   begin
      Encode (Input, Opt, Stream, Length, Stats);
      if Opt.Features /= null then
         Ada.Text_IO.Close (Features);
      end if;
      Encoded := Ada.Real_Time.Clock;
      Write_Stream (Stream (0 .. Length - 1));
      for B of Stream (0 .. Length - 1) loop
         Hash := (Hash xor Unsigned_64 (B)) * 1099511628211;
      end loop;
      if Option ("--flip") > 0 and then Option ("--flip") + 2 <= Ada.Command_Line.Argument_Count then
         declare
            G : constant Natural := Natural'Value (Ada.Command_Line.Argument (Option ("--flip") + 1));
            K : constant Natural := Natural'Value (Ada.Command_Line.Argument (Option ("--flip") + 2));
            P : constant Natural := Header_Length + Stats.Group_Starts (G) + K;
         begin
            Stream (P) := Stream (P) xor 16#80#;
         end;
      end if;

      --  Read the stream back from its own bytes, compare every sample, then decode the groups of the frame
      --  "--seek" names from its seek point alone.
      declare
         Decode_Start : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
         H : Stream_Reading.Header;
         Output : Stream_Reading.Channel_Buffers;
         Lost : Stream_Reading.Boolean_Array_Access;
         D : Stream_Reading.Damage;
         Wrong : Natural := 0;
         Decoded : Ada.Real_Time.Time;
      begin
         Stream_Reading.Read_Header (Stream (0 .. Length - 1), H);
         Same := Same and then H.Ok and then H.Rate = Rate and then H.Frames = Frames and then H.Channels = Channels
           and then H.Depth = Input.Depth and then H.Valid_Bits = Input.Valid_Bits and then H.Is_Float = Input.Is_Float
           and then H.Channel_Mask = Input.Channel_Mask and then H.Audio_Md5 = Audio_Md5
           and then (H.Source = null) = (Input.Source = null) and then (Input.Source = null or else H.Source.all = Input.Source.all)
           and then (for all C in 1 .. Channels => H.Modes (C) = Mode (C) and then H.Scales (C) = Scale (C));
         if H.Ok then
            Stream_Reading.Decode_All (Stream (0 .. Length - 1), H, Output, Lost, D, Verify => False);
            for C in 1 .. Channels loop
               for I in 0 .. Frames - 1 loop
                  if not Lost (I) and then (if Mode (C) = 1 then From_Integer (Output (C) (I), Scale (C)) else Output (C) (I)) /= Original (C, I) then
                     Wrong := Wrong + 1;
                  end if;
               end loop;
            end loop;
         end if;
         Same := Same and then D.Blocks_Ok and then D.Complete and then D.Bad_Crcs = 0 and then Wrong = 0 and then D.Lost_Frames = 0;
         Decoded := Ada.Real_Time.Clock;

         Put_Line (Ada.Command_Line.Argument (1));
         Put ("  Block codec, Ada and SPARK                         ");
         Put_Real (Long_Float (Length * 8) / Long_Float (Frames * Channels));
         Put ((if Same then "  round trip OK, hash " else "  ROUND TRIP FAILED, hash "));
         declare
            Hex : constant String := "0123456789abcdef";
            Text : String (1 .. 16);
         begin
            for K in 1 .. 16 loop
               Text (K) := Hex (Natural (Shift_Right (Hash, 4 * (16 - K)) and 15) + 1);
            end loop;
            Put (Text);
         end;
         Put (", encode");
         Put_Real (Long_Float (Ada.Real_Time.To_Duration (Encoded - Start)), 2);
         Put (" s, decode");
         Put_Real (Long_Float (Ada.Real_Time.To_Duration (Decoded - Decode_Start)), 2);
         Put_Line (" s, level" & Level'Image & "," & Length'Image & " bytes");
         Put ("    blocks: constant" & Kinds (0)'Image & ", orders 0-4");
         for K in 1 .. 5 loop
            Put (Kinds (K)'Image);
         end loop;
         Put_Line (", delay" & Kinds (6)'Image & ", tiers" & Kinds (7)'Image & ", LPC" & Kinds (8)'Image & "; Rice" & Kinds (9)'Image
                   & ", run-length" & Kinds (10)'Image & ", adaptive" & Kinds (12)'Image & "; adaptive stage" & Kinds (11)'Image
                   & (if Input.Is_Float then "; float as " & (if Mode (1) = 1 then "integers / 2**" & Scale (1)'Image else "ordered bits") else ""));
         Put_Line ("    bits: headers" & Side.Headers'Image & ", LPC coefficients" & Side.Coefficients'Image & ", LPC warm-up" & Side.Warm_Up'Image
                   & ", code tables" & Side.Tables'Image & ", residuals" & Side.Residuals'Image & ", framing"
                   & Long_Long_Integer (8 * (Header_Length + Framing))'Image & "; coefficients in Rice or Exp-Golomb codes"
                   & Side.Coded_Coefficients'Image & ", warm-up at the residual rate" & Side.Seeded_Warm_Up'Image);
         Put_Line ("    frames per block: 4096" & Leaves (0)'Image & ", 2048" & Leaves (1)'Image & ", 1024" & Leaves (2)'Image
                   & ", 512" & Leaves (3)'Image);
         if Pairs > 0 then
            Put ("    stereo:");
            for M in 0 .. 3 loop
               Put (" " & Mode_Names (M) (1 .. (if M = 3 then 8 elsif M = 1 then 9 else 10)) & Stereo (M)'Image & (if M < 3 then "," else ""));
            end loop;
            New_Line;
         end if;
         Put_Line ("    framing: header" & Header_Length'Image & " bytes," & Groups'Image & " groups," & Blocks'Image & " blocks,"
                   & Framing'Image & " bytes of group headers and tables, "
                   & (if Independent then "every group a segment" elsif Segment_Span = 0 then "one segment"
                      else "a segment every" & Segment_Span'Image & " groups") & "," & Natural'Image (H.Seeks'Length) & " seek points"
                   & (if H.Tag_Count > 0 then "; tags " & Ada.Strings.Unbounded.To_String (H.Tags) else "")
                   & "; audio MD5 " & Audio_Digest.Image (Audio_Md5)
                   & (if Input.Source /= null then "; source" & Natural'Image (Input.Source'Length) & " bytes" else "")
                   & (if Input.Foreign_Dropped then ", chunks other than format and audio too large to keep" else ""));
         if D.Bad_Groups > 0 or else D.Bad_Crcs > 0 or else Wrong > 0 then
            Put_Line ("    damage:" & D.Bad_Groups'Image & " groups failed," & D.Bad_Crcs'Image & " block CRCs failed," & D.Lost_Frames'Image
                      & " frames lost," & Wrong'Image & " samples wrong outside them" & (if Wrong = 0 then "; damage contained" else ""));
         end if;

         if Option ("--seek") > 0 and then H.Ok then
            declare
               Target : constant Natural := Natural'Min (Option_Value ("--seek", 0), Frames - 1);
               Buf : Stream_Reading.Channel_Buffers;
               Floor, Hops, Count, Last_First, Last_Count : Natural;
               Ok : Boolean;
               Seek_Same : Boolean := True;
            begin
               Stream_Reading.Decode_From (Stream (0 .. Length - 1), H, Target, Buf, Floor, Hops, Count, Last_First, Last_Count, Ok);
               if Ok then
                  for C in 1 .. Channels loop
                     for I in Target .. Last_First + Last_Count - 1 loop
                        Seek_Same := Seek_Same and then Buf (C) (I) = Output (C) (I);
                     end loop;
                  end loop;
               end if;
               Put_Line ("    seek to frame" & Target'Image & ": from frame" & Floor'Image & "," & Hops'Image & " groups skipped,"
                         & Count'Image & " decoded, " & (if Ok and then Seek_Same then "samples match" else "SAMPLES DIFFER"));
            end;
         end if;
      end;
   end;
end Codec_Main;
