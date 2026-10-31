--  Code a WAV file with the block codec, decode it again and compare every sample. Prints the size, a hash of
--  the coded stream, the wall time of each step, and which block coding was chosen how often.
--  Usage: codec_main <file.wav>
with Ada.Command_Line;
with Ada.Real_Time;
with Ada.Text_IO;
with Interfaces; use Interfaces;
with Bit_Streams; use Bit_Streams;
with Block_Codec; use Block_Codec;
with Huffman_Codes; use Huffman_Codes;
with Wav_Files;

procedure Codec_Main is
   use Ada.Text_IO;
   use type Ada.Real_Time.Time;

   package Real_Text is new Float_IO (Long_Float);

   type Byte_Array_Access is access Byte_Array;

   --  Float bit patterns from the order-keeping integers of Wav_Files, and back.
   function Bits_Of (V : Long_Long_Integer) return Long_Long_Integer is (if V >= 0 then V else 2**31 - 1 - V);
   function Ordered (B : Long_Long_Integer) return Long_Long_Integer is (if B >= 2**31 then 2**31 - 1 - B else B);

   function Trailing_Zeros (F : Long_Long_Integer) return Natural is
      T : Natural := 0;
   begin
      while (F / 2**T) mod 2 = 0 loop
         T := T + 1;
      end loop;
      return T;
   end Trailing_Zeros;

   --  Replace float samples by integers I with sample = I / 2**S, when one S up to 31 fits every sample.
   procedure To_Integers (X : in out Value_Array; S : out Natural; Ok : out Boolean) is
      Fraction : Long_Long_Integer := 0;
      Y : Value_Array_Access := new Value_Array (X'Range);
   begin
      Ok := False;
      S := 0;
      for V of X loop
         declare
            B : constant Long_Long_Integer := Bits_Of (V);
            E : constant Long_Long_Integer := (B / 2**23) mod 256;
         begin
            if B = 2**31 or else E = 255 or else (E = 0 and then B mod 2**23 /= 0) then
               Free (Y);
               return;
            end if;
            if B mod 2**31 /= 0 then
               Fraction := Long_Long_Integer'Max (Fraction, 150 - E - Long_Long_Integer (Trailing_Zeros (2**23 + B mod 2**23)));
            end if;
         end;
      end loop;
      if Fraction > 31 then
         Free (Y);
         return;
      end if;
      for I in X'Range loop
         declare
            B : constant Long_Long_Integer := Bits_Of (X (I));
            E : constant Long_Long_Integer := (B / 2**23) mod 256;
            F : constant Long_Long_Integer := 2**23 + B mod 2**23;
            Up : constant Long_Long_Integer := E - 150 + Fraction;
            Magnitude : Long_Long_Integer;
         begin
            if B mod 2**31 = 0 then
               Y (I) := 0;
            else
               if Up > 7 then
                  Free (Y);
                  return;
               end if;
               Magnitude := (if Up >= 0 then F * 2**Natural (Up) else F / 2**Natural (-Up));
               if Magnitude >= 2**31 then
                  Free (Y);
                  return;
               end if;
               Y (I) := (if B >= 2**31 then -Magnitude else Magnitude);
            end if;
         end;
      end loop;
      X := Y.all;
      Free (Y);
      S := Natural (Fraction);
      Ok := True;
   end To_Integers;

   function From_Integer (I : Long_Long_Integer; S : Natural) return Long_Long_Integer is
   begin
      if I = 0 then
         return 0;
      end if;
      declare
         A : constant Long_Long_Integer := abs I;
         L : Natural := 0;
      begin
         while 2**L <= A loop
            L := L + 1;
         end loop;
         declare
            F : constant Long_Long_Integer := (if L <= 24 then A * 2**(24 - L) else A / 2**(L - 24));
            E : constant Long_Long_Integer := Long_Long_Integer (L) - 1 - Long_Long_Integer (S) + 127;
         begin
            return Ordered ((if I < 0 then 2**31 else 0) + E * 2**23 + (F - 2**23));
         end;
      end;
   end From_Integer;

   procedure Put_Real (Value : Long_Float; Aft : Natural := 2) is
   begin
      Real_Text.Put (Value, Fore => 3, Aft => Aft, Exp => 0);
   end Put_Real;

   Input : Wav_Files.Audio;
begin
   Wav_Files.Read (Ada.Command_Line.Argument (1), 3600, Input);
   declare
      Frames : constant Natural := Input.Frames;
      Channels : constant Natural := Input.Channels;
      Blocks : constant Natural := (Frames + Max_Block - 1) / Max_Block;
      Depth : constant Sample_Bits := (if Input.Is_Float then 32 else Input.Depth);
      Mode : array (1 .. Channels) of Natural := [others => 0];
      Scale : array (1 .. Channels) of Natural := [others => 0];
      Header : constant Natural := 7 + (if Input.Is_Float then 2 * Channels else 0) + 4 * Channels * Blocks;
      Stream : constant Byte_Array_Access := new Byte_Array (0 .. Header + Channels * Blocks * Bound (Max_Block));
      Length : Natural := Header;
      Sizes : array (0 .. Channels * Blocks - 1) of Natural;
      Pos : Natural := 0;
      Start : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      Encoded : Ada.Real_Time.Time;
      Same : Boolean := True;
      Hash : Unsigned_64 := 14695981039346656037;
      Kinds : array (0 .. 9) of Natural := [others => 0];
   begin
      if Input.Is_Float then
         for C in 1 .. Channels loop
            declare
               Ok : Boolean;
            begin
               To_Integers (Input.Samples (C).all, Scale (C), Ok);
               Mode (C) := (if Ok then 1 else 2);
            end;
         end loop;
      end if;
      Put (Stream.all, Pos, Unsigned_64 (Frames), 32);
      Put (Stream.all, Pos, Unsigned_64 (Channels), 8);
      Put (Stream.all, Pos, Unsigned_64 (Input.Depth), 8);
      Put (Stream.all, Pos, Boolean'Pos (Input.Is_Float), 8);
      if Input.Is_Float then
         for C in 1 .. Channels loop
            Put (Stream.all, Pos, Unsigned_64 (Mode (C)), 8);
            Put (Stream.all, Pos, Unsigned_64 (Scale (C)), 8);
         end loop;
      end if;
      for C in 1 .. Channels loop
         for B in 0 .. Blocks - 1 loop
            declare
               First : constant Natural := B * Max_Block;
               Last : constant Natural := Natural'Min (First + Max_Block, Frames) - 1;
               Bytes : Natural;
            begin
               Encode (Sample_Array (Input.Samples (C) (First .. Last)), Depth, Stream (Length .. Length + Bound (Max_Block) - 1), Bytes);
               Sizes ((C - 1) * Blocks + B) := Bytes;
               declare
                  Kind_Pos : Natural := Length * 8;
                  Field : Unsigned_64;
               begin
                  Get (Stream.all, Kind_Pos, Field, 1);
                  if Field = 0 then
                     Kinds (0) := Kinds (0) + 1;
                  else
                     Get (Stream.all, Kind_Pos, Field, 5);
                     Get (Stream.all, Kind_Pos, Field, 3);
                     Kinds (1 + Natural (Field)) := Kinds (1 + Natural (Field)) + 1;
                     if Field = 5 then
                        Get (Stream.all, Kind_Pos, Field, 12);
                     end if;
                     Get (Stream.all, Kind_Pos, Field, 1);
                     Kinds (8 + Natural (Field)) := Kinds (8 + Natural (Field)) + 1;
                  end if;
               end;
               Length := Length + Bytes;
            end;
         end loop;
      end loop;
      for I in Sizes'Range loop
         Put (Stream.all, Pos, Unsigned_64 (Sizes (I)), 32);
      end loop;
      Encoded := Ada.Real_Time.Clock;

      declare
         Offset : Natural := Header;
         Out_Block : Sample_Array (0 .. Max_Block - 1);
         Status : Status_Type;
         Used : Natural;
      begin
         for C in 1 .. Channels loop
            for B in 0 .. Blocks - 1 loop
               declare
                  First : constant Natural := B * Max_Block;
                  Count : constant Natural := Natural'Min (First + Max_Block, Frames) - First;
                  Size : constant Natural := Sizes ((C - 1) * Blocks + B);
               begin
                  Decode (Stream (Offset .. Offset + Size - 1), Depth, Out_Block (0 .. Count - 1), Used, Status);
                  Same := Same and then Used = Size;
                  for K in 0 .. Count - 1 loop
                     declare
                        V : constant Long_Long_Integer :=
                          (if Mode (C) = 1 then From_Integer (Out_Block (K), Scale (C)) else Out_Block (K));
                        Original : constant Long_Long_Integer :=
                          (if Mode (C) = 1 then From_Integer (Input.Samples (C) (First + K), Scale (C)) else Input.Samples (C) (First + K));
                     begin
                        Same := Same and then Status = Success and then V = Original;
                     end;
                  end loop;
                  Offset := Offset + Size;
               end;
            end loop;
         end loop;
         Same := Same and then Offset = Length;
      end;
      for B of Stream (0 .. Length - 1) loop
         Hash := (Hash xor Unsigned_64 (B)) * 1099511628211;
      end loop;

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
      Put_Real (Long_Float (Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Encoded)), 2);
      Put_Line (" s");
      Put ("    blocks: constant" & Kinds (0)'Image & ", orders 0-4");
      for K in 1 .. 5 loop
         Put (Kinds (K)'Image);
      end loop;
      Put_Line (", delay" & Kinds (6)'Image & ", tiers" & Kinds (7)'Image & "; Rice" & Kinds (8)'Image & ", run-length" & Kinds (9)'Image
                & (if Input.Is_Float then "; float as " & (if Mode (1) = 1 then "integers / 2**" & Scale (1)'Image else "ordered bits") else ""));
   end;
end Codec_Main;
