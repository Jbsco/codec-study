--  Decode a stream written by codec_main --stream or stream_encode into the file it came from, from the stream's own
--  bytes, group by group, so memory does not grow with the audio's length. Frames of a group that cannot be read
--  are written as zeros and reported. "-" names standard input or standard output.
--  Usage: stream_decode <stream.bin> <out.wav>
--  Exit status: 0 decoded intact, 1 written with damage or with audio that differs from its MD5, 2 not a readable
--  stream or wrong arguments.
with Ada.Command_Line;
with Ada.Directories;
with Ada.Streams;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Audio_Digest;
with Bit_Streams; use Bit_Streams;
with Byte_Files;
with Stream_Format; use Stream_Format;
with Stream_Reading; use Stream_Reading;
with Wav_Files;

procedure Stream_Decode is
   use Ada.Text_IO;

   procedure Fail (Message : String) is
   begin
      Put_Line (Standard_Error, "stream_decode: " & Message);
      Ada.Command_Line.Set_Exit_Status (2);
   end Fail;
begin
   if Ada.Command_Line.Argument_Count /= 2 then
      Fail ("usage: stream_decode <stream.bin> <out.wav>");
      return;
   end if;
   declare
      Name : constant String := Ada.Command_Line.Argument (1);
      Out_Name : constant String := Ada.Command_Line.Argument (2);
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
         declare
            W : Walker;
            Check : Audio_Digest.Hasher;
            Recorded : constant Boolean := H.Audio_Md5 /= Audio_Digest.Not_Recorded;
            Written : Boolean := False;
            Audio : Audio_Check := Not_Recorded;

            --  Each sample in frame order, as the writer asks for them, fed to the MD5 on the way.
            function Sample (C : Positive; F : Natural) return Long_Long_Integer is
               V : Long_Long_Integer;
            begin
               Advance (W, F);
               V := Value (W, C, F);
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
            if Recorded then
               Audio_Digest.Start (Check, H.Depth, H.Valid_Bits, H.Is_Float);
            end if;
            if H.Source /= null then
               Wav_Files.Write_Source (Out_Name, H.Source.all, H.Channels, H.Depth, H.Valid_Bits, H.Is_Float, H.Frames,
                                       Sample'Access, Written);
               if not Written then
                  Put_Line (Standard_Error, Name & ": source description does not match the audio, writing a WAV file");
               end if;
            end if;
            if not Written then
               Wav_Files.Write (Out_Name, H.Channels, H.Rate, H.Depth, H.Valid_Bits, H.Channel_Mask, H.Is_Float, H.Frames,
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
                         & (case Audio is when Matches => ", audio MD5 matches", when Differs => ", AUDIO MD5 DIFFERS",
                            when Not_Recorded => ", no audio MD5 recorded", when Not_Checked => ""));
               if D.Complete and then D.Blocks_Ok and then D.Bad_Crcs = 0 and then Audio /= Differs then
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
   end;
end Stream_Decode;
