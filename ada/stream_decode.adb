--  Decode a stream written by codec_main --stream into a WAV file, from the stream's own bytes. Frames of a
--  group that cannot be read are written as zeros and reported.
--  Usage: stream_decode <stream.bin> <out.wav>
--  Exit status: 0 decoded intact, 1 written with damage, 2 not a readable stream or wrong arguments.
with Ada.Command_Line;
with Ada.Directories;
with Ada.Streams.Stream_IO;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Bit_Streams; use Bit_Streams;
with Stream_Format; use Stream_Format;
with Stream_Reading; use Stream_Reading;
with Wav_Files;

procedure Stream_Decode is
   use Ada.Text_IO;
   use Ada.Streams;

   type Element_Array_Access is access Stream_Element_Array;

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
   begin
      if not Ada.Directories.Exists (Name) then
         Fail (Name & ": no such file");
         return;
      end if;
      declare
         Size : constant Natural := Natural (Ada.Directories.Size (Name));
         Raw : constant Element_Array_Access := new Stream_Element_Array (1 .. Stream_Element_Offset (Size));
         Last : Stream_Element_Offset;
         File : Stream_IO.File_Type;
         Stream : constant Byte_Array_Access := new Byte_Array (0 .. Size - 1);
         H : Header;
      begin
         Stream_IO.Open (File, Stream_IO.In_File, Name);
         Stream_IO.Read (File, Raw.all, Last);
         Stream_IO.Close (File);
         for I in 0 .. Size - 1 loop
            Stream (I) := Byte (Raw (Stream_Element_Offset (I + 1)));
         end loop;
         Read_Header (Stream.all, H);
         if not H.Ok then
            Fail (Name & ": not a readable stream (magic, version, field or header CRC)");
            return;
         end if;
         declare
            Output : Channel_Buffers;
            Lost : Boolean_Array_Access;
            D : Damage;

            function Sample (C : Positive; F : Natural) return Long_Long_Integer is
              (if H.Is_Float and then H.Modes (C) = 1 then From_Integer (Output (C) (F), H.Scales (C)) else Output (C) (F));
         begin
            begin
               Decode_All (Stream.all, H, Output, Lost, D);
            exception
               when Storage_Error =>
                  Fail (Name & ": the header claims" & H.Frames'Image & " frames, more than memory holds");
                  return;
            end;
            Wav_Files.Write (Ada.Command_Line.Argument (2), H.Channels, H.Rate, H.Depth, H.Is_Float, H.Frames, Sample'Access);
            Put_Line (Standard_Error, Name & ":" & H.Frames'Image & " frames," & H.Channels'Image & " channels,"
                      & H.Rate'Image & " Hz," & H.Depth'Image & (if H.Is_Float then "-bit float" else "-bit")
                      & (if H.Tag_Count > 0 then ", tags " & Ada.Strings.Unbounded.To_String (H.Tags) else ""));
            if D.Complete and then D.Blocks_Ok and then D.Bad_Crcs = 0 then
               Ada.Command_Line.Set_Exit_Status (0);
            else
               Put_Line (Standard_Error, Name & ": damaged," & D.Bad_Groups'Image & " groups failed," & D.Bad_Crcs'Image
                         & " block CRCs failed," & D.Lost_Frames'Image & " frames lost and written as zeros"
                         & (if D.Blocks_Ok then "" else ", blocks that did not decode written as zeros"));
               Ada.Command_Line.Set_Exit_Status (1);
            end if;
         end;
      end;
   end;
end Stream_Decode;
