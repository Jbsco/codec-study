--  Mutation fuzzer for the stream decoder. Each iteration takes one of the given streams, changes it at random and
--  decodes it as stream_decode does: header, walker, audio MD5 and the writer, into /dev/null. Some changes rewrite a
--  header or group field and recompute its CRC, so the change reaches the parsers behind the CRCs. Any exception is
--  a failure: the changed stream is saved as fuzz_failure.blkc and the exit status is 1. With 0 iterations, each
--  stream is decoded once as given, to replay a saved failure.
--  Usage: fuzz_decode <iterations> <seed> <stream>...
with Ada.Command_Line;
with Ada.Exceptions;
with Ada.Streams.Stream_IO;
with Ada.Text_IO;
with Ada.Unchecked_Deallocation;
with Interfaces; use Interfaces;
with Audio_Digest;
with Bit_Streams; use Bit_Streams;
with Byte_Files;
with Checksums;
with Stream_Format; use Stream_Format;
with Stream_Reading; use Stream_Reading;
with Wav_Files;

procedure Fuzz_Decode is
   use Ada.Text_IO;

   Count : constant Natural := Ada.Command_Line.Argument_Count - 2;
   type Stream_List is array (1 .. Count) of Byte_Array_Access;
   Seeds : Stream_List;
   Header_End : array (1 .. Count) of Natural := [others => 0];
   State : Unsigned_64 := 0;

   procedure Free is new Ada.Unchecked_Deallocation (Byte_Array, Byte_Array_Access);
   Refused, Intact, Damaged, Skipped : Natural := 0;

   --  xorshift64*: a fixed sequence for each seed, so a failure can be found again.
   function Next return Unsigned_64 is
   begin
      State := State xor Shift_Right (State, 12);
      State := State xor Shift_Left (State, 25);
      State := State xor Shift_Right (State, 27);
      return State * 16#2545_F491_4F6C_DD1D#;
   end Next;

   function Below (N : Positive) return Natural is (Natural (Next mod Unsigned_64 (N)));

   function Load (Name : String) return Byte_Array_Access is
      Raw : constant Byte_Files.Bytes_Access := Byte_Files.Load (Name);
      S : constant Byte_Array_Access := new Byte_Array (0 .. Natural (Raw'Length) - 1);
   begin
      for I in S'Range loop
         S (I) := Byte (Raw (Ada.Streams.Stream_Element_Offset (I)));
      end loop;
      return S;
   end Load;

   --  The position of a header's CRC, the byte after its metadata blocks, or 0 when S is too short to have one.
   function Crc_Position (S : Byte_Array) return Natural is
      P : Natural;
   begin
      if S'Length < 64 then
         return 0;
      end if;
      P := 42 + (if S (21) = 1 then 2 * Natural (S (18)) else 0);
      if P >= S'Length then
         return 0;
      end if;
      declare
         Blocks : constant Natural := Natural (S (P));
      begin
         P := P + 1;
         for Unused in 1 .. Blocks loop
            if P + 3 >= S'Length then
               return 0;
            end if;
            P := P + 4 + Natural (S (P + 1)) * 65536 + Natural (S (P + 2)) * 256 + Natural (S (P + 3));
         end loop;
      end;
      return (if P + 2 <= S'Length then P else 0);
   end Crc_Position;

   procedure Put_Crc (S : in out Byte_Array; At_Byte : Natural; From : Natural) is
      C : constant Unsigned_16 := Checksums.Of_Bytes (S (From .. At_Byte - 1));
   begin
      S (At_Byte) := Byte (Shift_Right (C, 8));
      S (At_Byte + 1) := Byte (C and 16#FF#);
   end Put_Crc;

   --  A changed copy of stream K, and which change was made.
   function Mutate (K : Positive; Kind : out Natural) return Byte_Array_Access is
      S : Byte_Array_Access := new Byte_Array'(Seeds (K).all);
      N : constant Natural := S'Length;
   begin
      Kind := Below (7);
      if Kind >= 5 and then Header_End (K) = 0 then
         Kind := 0;
      end if;
      --  Each change keeps the stream indexed from 0, as Read_Header requires.
      case Kind is
         when 0 =>
            for Unused in 1 .. 1 + Below (4) loop
               declare
                  P : constant Natural := Below (N);
               begin
                  S (P) := S (P) xor Byte (2**Below (8));
               end;
            end loop;
         when 1 =>
            for Unused in 1 .. 1 + Below (8) loop
               S (Below (N)) := Byte (Below (256));
            end loop;
         when 2 =>
            Free (S);
            S := new Byte_Array'(Seeds (K) (0 .. Below (N)));
         when 3 =>
            declare
               P : constant Natural := Below (N);
               Junk : Byte_Array (0 .. Below (64));
            begin
               for B of Junk loop
                  B := Byte (Below (256));
               end loop;
               Free (S);
               S := new Byte_Array (0 .. N + Junk'Length - 1);
               S.all := Seeds (K) (0 .. P - 1) & Junk & Seeds (K) (P .. N - 1);
            end;
         when 4 =>
            declare
               From : constant Natural := Below (N);
               Len : constant Natural := Natural'Min (Below (4096) + 1, N - From);
               P : constant Natural := Below (N);
            begin
               Free (S);
               S := new Byte_Array (0 .. N + Len - 1);
               S.all := Seeds (K) (0 .. P - 1) & Seeds (K) (From .. From + Len - 1) & Seeds (K) (P .. N - 1);
            end;
         when 5 =>
            declare
               H : constant Natural := Header_End (K);
            begin
               S (4 + Below (H - 4)) := Byte (Below (256));
               Put_Crc (S.all, H, 0);
            end;
         when others =>
            --  A field of a group header, with the group CRC recomputed where the original one stood.
            declare
               G : Natural := Header_End (K) + 2;
               Pick : Natural := Below (8);
            begin
               while Pick > 0 and then G + 5 < N loop
                  declare
                     Len : constant Natural := Natural (S (G + 2)) * 65536 + Natural (S (G + 3)) * 256 + Natural (S (G + 4));
                  begin
                     exit when Len < 13 or else G + Len + 13 > N;
                     G := G + Len;
                     Pick := Pick - 1;
                  end;
               end loop;
               if G + 13 <= N then
                  declare
                     P : Natural := G + 13;
                  begin
                     while P + 1 < N and then P < G + 4096
                       and then Checksums.Of_Bytes (S (G .. P - 1)) /= Unsigned_16 (S (P)) * 256 + Unsigned_16 (S (P + 1))
                     loop
                        P := P + 1;
                     end loop;
                     if P + 1 < N and then P < G + 4096 then
                        S (G + 2 + Below (P - G - 2)) := Byte (Below (256));
                        Put_Crc (S.all, P, G);
                     end if;
                  end;
               end if;
            end;
      end case;
      return S;
   end Mutate;

   --  Decode as stream_decode does, into /dev/null.
   procedure Decode (S : Byte_Array_Access) is
      H : Header;
   begin
      Read_Header (S.all, H);
      if not H.Ok then
         Refused := Refused + 1;
         return;
      end if;
      if H.Frames > 2**18 then
         Skipped := Skipped + 1;
         return;
      end if;
      declare
         W : Walker;
         Check : Audio_Digest.Hasher;
         Written : Boolean := False;
         Got : Audio_Digest.Digest;

         function Sample (C : Positive; F : Natural) return Long_Long_Integer is
            V : Long_Long_Integer;
         begin
            Advance (W, F);
            V := Value (W, C, F);
            if H.Is_Float and then H.Modes (C) = 1 then
               V := From_Integer (V, H.Scales (C));
            end if;
            Audio_Digest.Add (Check, V);
            return V;
         end Sample;
      begin
         Start (W, S, H);
         Audio_Digest.Start (Check, H.Depth, H.Valid_Bits, H.Is_Float);
         if H.Source /= null then
            Wav_Files.Write_Source ("/dev/null", H.Source.all, H.Channels, H.Depth, H.Valid_Bits, H.Is_Float, H.Frames,
                                    Sample'Access, Written);
         end if;
         if not Written then
            Wav_Files.Write ("/dev/null", H.Channels, H.Rate, H.Depth, H.Valid_Bits, H.Channel_Mask, H.Is_Float, H.Frames,
                             Sample'Access);
         end if;
         Audio_Digest.Finish (Check, Got);
         declare
            D : constant Damage := Report (W);
         begin
            if D.Complete and then D.Blocks_Ok and then D.Bad_Crcs = 0 and then Got = H.Audio_Md5 then
               Intact := Intact + 1;
            else
               Damaged := Damaged + 1;
            end if;
         end;
         Stop (W);
      end;
   end Decode;

   Iterations : Natural;
begin
   if Count < 1 then
      Put_Line (Standard_Error, "usage: fuzz_decode <iterations> <seed> <stream>...");
      Ada.Command_Line.Set_Exit_Status (2);
      return;
   end if;
   Iterations := Natural'Value (Ada.Command_Line.Argument (1));
   State := Unsigned_64'Value (Ada.Command_Line.Argument (2)) * 2 + 1;
   for K in 1 .. Count loop
      Seeds (K) := Load (Ada.Command_Line.Argument (K + 2));
      if Iterations = 0 then
         begin
            Decode (Seeds (K));
         exception
            when E : others =>
               Put_Line (Standard_Error, "fuzz_decode: " & Ada.Command_Line.Argument (K + 2) & ": "
                         & Ada.Exceptions.Exception_Information (E));
               Ada.Command_Line.Set_Exit_Status (1);
               return;
         end;
      else
         Header_End (K) := Crc_Position (Seeds (K).all);
      end if;
   end loop;
   for I in 1 .. Iterations loop
      declare
         K : constant Positive := 1 + Below (Count);
         Kind : Natural;
         S : Byte_Array_Access := Mutate (K, Kind);
      begin
         Decode (S);
         Free (S);
      exception
         when E : others =>
            declare
               F : Ada.Streams.Stream_IO.File_Type;
               Bytes : Ada.Streams.Stream_Element_Array (1 .. Ada.Streams.Stream_Element_Offset (S'Length));
               for Bytes'Address use S.all'Address;
            begin
               Ada.Streams.Stream_IO.Create (F, Ada.Streams.Stream_IO.Out_File, "fuzz_failure.blkc");
               Ada.Streams.Stream_IO.Write (F, Bytes);
               Ada.Streams.Stream_IO.Close (F);
            end;
            Put_Line (Standard_Error, "fuzz_decode: iteration" & I'Image & ", " & Ada.Command_Line.Argument (K + 2)
                      & ", change" & Kind'Image & ": " & Ada.Exceptions.Exception_Information (E));
            Put_Line (Standard_Error, "fuzz_decode: stream saved as fuzz_failure.blkc");
            Ada.Command_Line.Set_Exit_Status (1);
            return;
      end;
   end loop;
   Put_Line ("fuzz_decode:" & Iterations'Image & " changed streams, no exception:" & Refused'Image & " refused,"
             & Intact'Image & " intact," & Damaged'Image & " damaged," & Skipped'Image & " skipped for length");
end Fuzz_Decode;
