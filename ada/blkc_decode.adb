--  Decode a stream written by codec_main --stream or blkc-encode into the file it came from, from the stream's own
--  bytes, group by group, so memory does not grow with the audio's length. Frames of a group that cannot be read
--  are written as zeros and reported. "-" names standard input or standard output. --skip and --until write frames
--  from the first named up to the second as a WAV file, decoding from the groups those frames need.
--  Usage: blkc-decode [--skip <frame>] [--until <frame>] <stream.bin> <out.wav>, or blkc-decode --version
--  Exit status: 0 decoded intact, 1 written with damage or with audio that differs from its MD5, 2 not a readable
--  stream or wrong arguments.
with Ada.Command_Line;
with Ada.Directories;
with Ada.Streams;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Audio_Digest;
with Bit_Streams; use Bit_Streams;
with Build_Version;
with Byte_Files;
with Stream_Format; use Stream_Format;
with Stream_Reading; use Stream_Reading;
with Wav_Files;

procedure Blkc_Decode is
   use Ada.Text_IO;

   procedure Fail (Message : String) is
   begin
      Put_Line (Standard_Error, "blkc-decode: " & Message);
      Ada.Command_Line.Set_Exit_Status (2);
   end Fail;

   procedure Decode (Name, Out_Name : String; Skip, Until_Frame : Natural; Ranged : Boolean) is
   begin
      if Name /= "-" and then not Ada.Directories.Exists (Name) then
         Fail (Name & ": no such file");
         return;
      end if;
      declare
         Raw : constant Byte_Files.Bytes_Access := Byte_Files.Load (Name);
         Stream : constant Byte_Array_Access := new Byte_Array (0 .. Natural (Raw'Length) - 1);
         H : Header;
      begin
         for I in Stream'Range loop
            Stream (I) := Byte (Raw (Ada.Streams.Stream_Element_Offset (I)));
         end loop;
         Read_Header (Stream.all, H);
         if not H.Ok then
            Fail (Name & ": not a readable stream (magic, version, field or header CRC)");
            return;
         end if;
         if Skip > Natural'Min (Until_Frame, H.Frames) then
            Fail (Name & ": --skip past --until or past the stream's" & H.Frames'Image & " frames");
            return;
         end if;
         declare
            Last : constant Natural := Natural'Min (Until_Frame, H.Frames);
            W : Walker;
            Check : Audio_Digest.Hasher;
            Recorded : constant Boolean := H.Audio_Md5 /= Audio_Digest.Not_Recorded and then not Ranged;
            Written : Boolean := False;
            Audio : Audio_Check := Not_Recorded;

            --  Each sample in frame order, as the writer asks for them, fed to the MD5 on the way.
            function Sample (C : Positive; F : Natural) return Long_Long_Integer is
               V : Long_Long_Integer;
            begin
               Advance (W, Skip + F);
               V := Value (W, C, Skip + F);
               if H.Is_Float and then H.Modes (C) = 1 then
                  V := From_Integer (V, H.Scales (C));
               end if;
               if Recorded then
                  Audio_Digest.Add (Check, V);
               end if;
               return V;
            end Sample;
         begin
            Start (W, Stream, H);
            if Skip > 0 and then Skip < H.Frames then
               Seek (W, Skip);
            end if;
            if Recorded then
               Audio_Digest.Start (Check, H.Depth, H.Valid_Bits, H.Is_Float);
            end if;
            if H.Source /= null and then not Ranged then
               Wav_Files.Write_Source (Out_Name, H.Source.all, H.Channels, H.Depth, H.Valid_Bits, H.Is_Float, H.Frames,
                                       Sample'Access, Written);
               if not Written then
                  Put_Line (Standard_Error, Name & ": source description does not match the audio, writing a WAV file");
               end if;
            end if;
            if not Written then
               Wav_Files.Write (Out_Name, H.Channels, H.Rate, H.Depth, H.Valid_Bits, H.Channel_Mask, H.Is_Float, Last - Skip,
                                Sample'Access);
            end if;
            if Recorded then
               declare
                  Got : Audio_Digest.Digest;
               begin
                  Audio_Digest.Finish (Check, Got);
                  Audio := (if Got = H.Audio_Md5 then Matches else Differs);
               end;
            end if;
            declare
               D : constant Damage := Report (W);
            begin
               Put_Line (Standard_Error, Name & ":" & H.Frames'Image & " frames," & H.Channels'Image & " channels,"
                         & H.Rate'Image & " Hz," & H.Depth'Image & (if H.Is_Float then "-bit float" else "-bit")
                         & (if H.Tag_Count > 0 then ", tags " & Ada.Strings.Unbounded.To_String (H.Tags) else "")
                         & (if Ranged then ", frames" & Skip'Image & " to" & Natural'Image (Last - 1) & " written" else "")
                         & (case Audio is when Matches => ", audio MD5 matches", when Differs => ", AUDIO MD5 DIFFERS",
                            when Not_Recorded => (if Ranged then "" else ", no audio MD5 recorded"),
                            when Not_Checked => ""));
               if (D.Complete or else (Ranged and then D.Lost_Frames = 0 and then D.Bad_Groups = 0)) and then D.Blocks_Ok
                 and then D.Bad_Crcs = 0 and then Audio /= Differs
               then
                  Ada.Command_Line.Set_Exit_Status (0);
               else
                  Put_Line (Standard_Error, Name & ": damaged," & D.Bad_Groups'Image & " groups failed," & D.Bad_Crcs'Image
                            & " block CRCs failed," & D.Lost_Frames'Image & " frames lost and written as zeros"
                            & (if D.Blocks_Ok then "" else ", blocks that did not decode written as zeros")
                            & (if Audio = Differs then ", audio MD5 differs from the header's" else ""));
                  Ada.Command_Line.Set_Exit_Status (1);
               end if;
            end;
         end;
      end;
   end Decode;

begin
   if Ada.Command_Line.Argument_Count = 1 and then Ada.Command_Line.Argument (1) = "--version" then
      Put_Line ("blkc-decode " & Build_Version.Version & ", format version" & Integer'Image (Version) & ", C API version 1");
      return;
   end if;
   declare
      use Ada.Strings.Unbounded;
      Usage : constant String := "usage: blkc-decode [--skip <frame>] [--until <frame>] <stream.bin> <out.wav>";
      Names : array (1 .. 2) of Unbounded_String;
      Named : Natural := 0;
      Skip : Natural := 0;
      Until_Frame : Natural := Natural'Last;
      Ranged : Boolean := False;
      I : Positive := 1;
   begin
      while I <= Ada.Command_Line.Argument_Count loop
         declare
            A : constant String := Ada.Command_Line.Argument (I);
         begin
            if (A = "--skip" or else A = "--until") and then I < Ada.Command_Line.Argument_Count then
               declare
                  V : constant Natural := Natural'Value (Ada.Command_Line.Argument (I + 1));
               begin
                  if A = "--skip" then
                     Skip := V;
                  else
                     Until_Frame := V;
                  end if;
               end;
               Ranged := True;
               I := I + 2;
            elsif Named < 2 and then (A = "-" or else A (A'First) /= '-') then
               Named := Named + 1;
               Names (Named) := To_Unbounded_String (A);
               I := I + 1;
            else
               Fail (Usage);
               return;
            end if;
         end;
      end loop;
      if Named /= 2 then
         Fail (Usage);
         return;
      end if;
      Decode (To_String (Names (1)), To_String (Names (2)), Skip, Until_Frame, Ranged);
   exception
      when Constraint_Error =>
         Fail (Usage);
   end;
end Blkc_Decode;


