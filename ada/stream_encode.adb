--  Code an audio file into a stream with the block codec.
--  Usage: stream_encode [--level <0 to 5>] [--tag <key=value>]... [--seek-every <seconds>] [--independent]
--         [--no-pairs] <in.wav> <out.bin>
--  Exit status: 0 written, 2 an unreadable input or wrong arguments.
with Ada.Command_Line;
with Ada.Exceptions;
with Ada.Streams.Stream_IO;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
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
   Bad : Boolean := False;

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
            & "[--no-pairs] <in.wav> <out.bin>");
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
      declare
         Out_Bytes : Stream_Element_Array (1 .. Stream_Element_Offset (Length));
         for Out_Bytes'Address use Stream.all'Address;
      begin
         Stream_IO.Create (File, Stream_IO.Out_File, Out_Name);
         Stream_IO.Write (File, Out_Bytes);
         Stream_IO.Close (File);
      end;
      Put_Line (Standard_Error, In_Name & ":" & Input.Frames'Image & " frames," & Input.Channels'Image & " channels,"
                & Input.Rate'Image & " Hz, level" & Opt.Level'Image & "," & Length'Image & " bytes");
   end;
end Stream_Encode;
