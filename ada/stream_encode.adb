--  Code an audio file into a stream with the block codec. "-" names standard input or standard output.
--  Usage: stream_encode [--level <0 to 5>] [--tag <key=value>]... [--seek-every <seconds>] [--independent]
--         [--no-pairs] [--verify] <in.wav> <out.bin>
--  --verify decodes the stream before writing it and checks every frame against the audio's MD5.
--  Exit status: 0 written, 1 verification failed and nothing written, 2 an unreadable input or wrong arguments.
with Ada.Command_Line;
with Ada.Exceptions;
with Ada.Streams.Stream_IO;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Audio_Digest;
with Bit_Streams; use Bit_Streams;
with Byte_Files;
with Stream_Reading;
with Stream_Format; use Stream_Format;
with Stream_Writing; use Stream_Writing;
with Wav_Files;

procedure Stream_Encode is
   use Ada.Text_IO;
   use Ada.Streams;

   Opt : Options;
   Names : array (1 .. 2) of Ada.Strings.Unbounded.Unbounded_String;
   Name_Count : Natural := 0;
   I : Positive := 1;
   Bad, Verify : Boolean := False;

   procedure Fail (Message : String) is
   begin
      Put_Line (Standard_Error, "stream_encode: " & Message);
      Ada.Command_Line.Set_Exit_Status (2);
   end Fail;

   --  The argument after option I as a natural number in Low .. High, or failure.
   function Value (Low, High : Natural) return Natural is
   begin
      if I = Ada.Command_Line.Argument_Count then
         Bad := True;
         return Low;
      end if;
      declare
         V : constant Natural := Natural'Value (Ada.Command_Line.Argument (I + 1));
      begin
         if V not in Low .. High then
            Bad := True;
         end if;
         return Natural'Max (Low, Natural'Min (High, V));
      end;
   exception
      when Constraint_Error =>
         Bad := True;
         return Low;
   end Value;
begin
   while I <= Ada.Command_Line.Argument_Count loop
      declare
         A : constant String := Ada.Command_Line.Argument (I);
      begin
         if A = "--level" then
            Opt.Level := Value (0, 5);
            I := I + 1;
         elsif A = "--seek-every" then
            Opt.Seek_Every := Value (0, 86_400);
            I := I + 1;
         elsif A = "--tag" and then I < Ada.Command_Line.Argument_Count and then Opt.Tag_Count < Max_Tags then
            Opt.Tag_Count := Opt.Tag_Count + 1;
            Opt.Tags (Opt.Tag_Count) := Ada.Strings.Unbounded.To_Unbounded_String (Ada.Command_Line.Argument (I + 1));
            I := I + 1;
         elsif A = "--independent" then
            Opt.Independent := True;
         elsif A = "--no-pairs" then
            Opt.Pairs := False;
         elsif A = "--verify" then
            Verify := True;
         elsif A'Length > 2 and then A (A'First .. A'First + 1) = "--" then
            Bad := True;
         elsif Name_Count < 2 then
            Name_Count := Name_Count + 1;
            Names (Name_Count) := Ada.Strings.Unbounded.To_Unbounded_String (A);
         else
            Bad := True;
         end if;
      end;
      I := I + 1;
   end loop;
   if Bad or else Name_Count /= 2 then
      Fail ("usage: stream_encode [--level <0 to 5>] [--tag <key=value>]... [--seek-every <seconds>] [--independent] "
            & "[--no-pairs] [--verify] <in.wav> <out.bin>");
      return;
   end if;
   declare
      In_Name : constant String := Ada.Strings.Unbounded.To_String (Names (1));
      Out_Name : constant String := Ada.Strings.Unbounded.To_String (Names (2));
      Input : Wav_Files.Audio;
      Stream : Byte_Array_Access;
      Length : Natural;
      Stats : Statistics;
      File : Stream_IO.File_Type;
   begin
      begin
         Wav_Files.Read (In_Name, 3600, Input);
      exception
         when E : Constraint_Error | Stream_IO.Name_Error =>
            Fail (Ada.Exceptions.Exception_Message (E));
            return;
      end;
      Encode (Input, Opt, Stream, Length, Stats);
      if Verify then
         declare
            Copy : constant Byte_Array_Access := new Byte_Array'(Stream (0 .. Length - 1));
            H : Stream_Reading.Header;
            W : Stream_Reading.Walker;
            Check : Audio_Digest.Hasher;
            Got : Audio_Digest.Digest;
            Ok : Boolean;
         begin
            Stream_Reading.Read_Header (Copy.all, H);
            Ok := H.Ok;
            if Ok then
               Stream_Reading.Start (W, Copy, H);
               Audio_Digest.Start (Check, H.Depth, H.Valid_Bits, H.Is_Float);
               for F in 0 .. H.Frames - 1 loop
                  Stream_Reading.Advance (W, F);
                  for C in 1 .. H.Channels loop
                     declare
                        V : Long_Long_Integer := Stream_Reading.Value (W, C, F);
                     begin
                        if H.Is_Float and then H.Modes (C) = 1 then
                           V := From_Integer (V, H.Scales (C));
                        end if;
                        Audio_Digest.Add (Check, V);
                     end;
                  end loop;
               end loop;
               Audio_Digest.Finish (Check, Got);
               declare
                  D : constant Stream_Reading.Damage := Stream_Reading.Report (W);
               begin
                  Ok := Got = Stats.Audio_Md5 and then D.Complete and then D.Blocks_Ok and then D.Bad_Crcs = 0;
               end;
            end if;
            if not Ok then
               Put_Line (Standard_Error, "stream_encode: " & In_Name & ": verification failed, the stream does not decode to "
                         & "the input; nothing written");
               Ada.Command_Line.Set_Exit_Status (1);
               return;
            end if;
         end;
      end if;
      declare
         Out_Bytes : Stream_Element_Array (1 .. Stream_Element_Offset (Length));
         for Out_Bytes'Address use Stream.all'Address;
      begin
         Byte_Files.Create (File, Out_Name);
         Stream_IO.Write (File, Out_Bytes);
         Stream_IO.Close (File);
      end;
      Put_Line (Standard_Error, In_Name & ":" & Input.Frames'Image & " frames," & Input.Channels'Image & " channels,"
                & Input.Rate'Image & " Hz, level" & Opt.Level'Image & "," & Length'Image & " bytes"
                & (if Verify then ", verified" else ""));
   end;
end Stream_Encode;
