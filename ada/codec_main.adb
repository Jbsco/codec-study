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
   type Sample_Array_Access is access Sample_Array;

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

   type Kind_Counts is array (0 .. 10) of Natural;

   --  Count the coding of the block at byte Offset: constant, predictor 0 to 7, then Rice or run-length codes.
   procedure Count_Kind (Stream : Byte_Array; Offset : Natural; Kinds : in out Kind_Counts) is
      Kind_Pos : Natural := Offset * 8;
      Field : Unsigned_64;
   begin
      Get (Stream, Kind_Pos, Field, 1);
      if Field = 0 then
         Kinds (0) := Kinds (0) + 1;
         return;
      end if;
      Get (Stream, Kind_Pos, Field, 5);
      Get (Stream, Kind_Pos, Field, 3);
      Kinds (1 + Natural (Field)) := Kinds (1 + Natural (Field)) + 1;
      if Field = 5 then
         Get (Stream, Kind_Pos, Field, 1);
         Get (Stream, Kind_Pos, Field, (if Field = 1 then 15 else 12));
      elsif Field = 7 then
         declare
            Order, Precision, K, Bit : Unsigned_64;
         begin
            Get (Stream, Kind_Pos, Order, 5);
            Get (Stream, Kind_Pos, Precision, 4);
            Kind_Pos := Kind_Pos + 5 + Natural (Order + 1) * Natural (Precision + 1);
            Get (Stream, Kind_Pos, K, 6);
            for Unused in 0 .. Order loop
               loop
                  Get (Stream, Kind_Pos, Bit, 1);
                  exit when Bit = 1;
               end loop;
               Kind_Pos := Kind_Pos + Natural (K);
            end loop;
         end;
      end if;
      Get (Stream, Kind_Pos, Field, 1);
      Kinds (9 + Natural (Field)) := Kinds (9 + Natural (Field)) + 1;
   end Count_Kind;

   --  V divided by two, rounded down.
   function Half_Down (V : Long_Long_Integer) return Long_Long_Integer is (if V >= 0 then V / 2 else -((1 - V) / 2));

   --  The two signals each stereo mode codes: left and right, left and side, side and right, mid and side, where
   --  signals 1 and 2 are the channels, 3 is the mid and 4 the side.
   Mode_Signals : constant array (0 .. 3, 1 .. 2) of Positive := [[1, 2], [1, 4], [4, 2], [3, 4]];
   Mode_Names : constant array (0 .. 3) of String (1 .. 10) := ["left/right", "left/side ", "side/right", "mid/side  "];

   Input : Wav_Files.Audio;
begin
   Wav_Files.Read (Ada.Command_Line.Argument (1), 3600, Input);
   declare
      Frames : constant Natural := Input.Frames;
      Channels : constant Natural := Input.Channels;
      Groups : constant Natural := (Frames + Max_Block - 1) / Max_Block;
      Depth : constant Sample_Bits := (if Input.Is_Float then 32 else Input.Depth);
      Pair : constant Boolean := Channels = 2;
      Mode : array (1 .. Channels) of Natural := [others => 0];
      Scale : array (1 .. Channels) of Natural := [others => 0];
      Mode_At : constant Natural := 7 + (if Input.Is_Float then 2 * Channels else 0);
      Header : constant Natural := Mode_At + (if Pair then (2 * Groups + 7) / 8 else 0) + 4 * Channels * Groups;
      Stream : constant Byte_Array_Access := new Byte_Array (0 .. Header + Channels * Groups * Bound (Max_Block));
      Length : Natural := Header;
      Sizes : array (0 .. Channels * Groups - 1) of Natural;
      Pos : Natural := 0;
      Start : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      Encoded : Ada.Real_Time.Time;
      Same : Boolean := True;
      Hash : Unsigned_64 := 14695981039346656037;
      Kinds : Kind_Counts := [others => 0];
      Stereo : array (0 .. 3) of Natural := [others => 0];
      Signal : array (1 .. Channels + 2) of Sample_Array_Access;
      Signal_Depth : array (1 .. Channels + 2) of Sample_Bits := [others => Depth];
      Trial : array (1 .. Channels + 2) of Byte_Array_Access;
      Coupled : Boolean;
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
      Coupled := Pair and then Mode (1) = Mode (2) and then Scale (1) = Scale (2);
      for C in 1 .. Channels loop
         Signal (C) := new Sample_Array'(Sample_Array (Input.Samples (C).all));
      end loop;
      if Coupled then
         Signal (3) := new Sample_Array (0 .. Frames - 1);
         Signal (4) := new Sample_Array (0 .. Frames - 1);
         for I in 0 .. Frames - 1 loop
            Signal (3) (I) := Half_Down (Signal (1) (I) + Signal (2) (I));
            Signal (4) (I) := Signal (1) (I) - Signal (2) (I);
         end loop;
         Signal_Depth (4) := Depth + 1;
      end if;
      for S in Trial'Range loop
         Trial (S) := new Byte_Array (0 .. Bound (Max_Block) - 1);
      end loop;
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
      for G in 0 .. Groups - 1 loop
         declare
            First : constant Natural := G * Max_Block;
            Last : constant Natural := Natural'Min (First + Max_Block, Frames) - 1;
            From : constant Natural := Natural'Max (0, First - Max_History);
            Bytes : array (1 .. Channels + 2) of Natural := [others => 0];
            Choice : Natural := 0;
            Mode_Pos : Natural := Mode_At * 8 + 2 * G;
         begin
            for S in 1 .. (if Coupled then 4 else Channels) loop
               Encode (Signal (S) (First .. Last), Signal (S) (From .. First - 1), Signal_Depth (S), Trial (S).all, Bytes (S));
            end loop;
            if Coupled then
               for M in 1 .. 3 loop
                  if Bytes (Mode_Signals (M, 1)) + Bytes (Mode_Signals (M, 2))
                    < Bytes (Mode_Signals (Choice, 1)) + Bytes (Mode_Signals (Choice, 2))
                  then
                     Choice := M;
                  end if;
               end loop;
            end if;
            if Pair then
               Put (Stream.all, Mode_Pos, Unsigned_64 (Choice), 2);
               Stereo (Choice) := Stereo (Choice) + 1;
            end if;
            for C in 1 .. Channels loop
               declare
                  S : constant Positive := (if Pair then Mode_Signals (Choice, C) else C);
               begin
                  Stream (Length .. Length + Bytes (S) - 1) := Trial (S) (0 .. Bytes (S) - 1);
                  Sizes (G * Channels + C - 1) := Bytes (S);
                  Count_Kind (Stream.all, Length, Kinds);
                  Length := Length + Bytes (S);
               end;
            end loop;
         end;
      end loop;
      Pos := (Mode_At + (if Pair then (2 * Groups + 7) / 8 else 0)) * 8;
      for I in Sizes'Range loop
         Put (Stream.all, Pos, Unsigned_64 (Sizes (I)), 32);
      end loop;
      Encoded := Ada.Real_Time.Clock;

      declare
         Offset : Natural := Header;
         Output : array (1 .. Channels) of Sample_Array_Access;
         Got : array (1 .. Channels) of Sample_Array_Access;
         Derived : constant Sample_Array_Access := new Sample_Array (0 .. Max_History - 1);
         Status : Status_Type;
         Used : Natural;
      begin
         for C in 1 .. Channels loop
            Output (C) := new Sample_Array (0 .. Frames - 1);
            Got (C) := new Sample_Array (0 .. Max_Block - 1);
         end loop;
         for G in 0 .. Groups - 1 loop
            declare
               First : constant Natural := G * Max_Block;
               Count : constant Natural := Natural'Min (First + Max_Block, Frames) - First;
               From : constant Natural := Natural'Max (0, First - Max_History);
               Mode_Pos : Natural := Mode_At * 8 + 2 * G;
               Field : Unsigned_64 := 0;
               Choice : Natural;
            begin
               if Pair then
                  Get (Stream.all, Mode_Pos, Field, 2);
               end if;
               Choice := Natural (Field);
               for C in 1 .. Channels loop
                  declare
                     S : constant Positive := (if Pair then Mode_Signals (Choice, C) else C);
                     Size : constant Natural := Sizes (G * Channels + C - 1);
                  begin
                     if S <= Channels then
                        Decode (Stream (Offset .. Offset + Size - 1), Output (S) (From .. First - 1), Signal_Depth (S),
                                Got (C) (0 .. Count - 1), Used, Status);
                     else
                        for I in From .. First - 1 loop
                           Derived (I - From) :=
                             (if S = 3 then Half_Down (Output (1) (I) + Output (2) (I)) else Output (1) (I) - Output (2) (I));
                        end loop;
                        Decode (Stream (Offset .. Offset + Size - 1), Derived (0 .. First - From - 1), Signal_Depth (S),
                                Got (C) (0 .. Count - 1), Used, Status);
                     end if;
                     Same := Same and then Status = Success and then Used = Size;
                     Offset := Offset + Size;
                  end;
               end loop;
               for K in 0 .. Count - 1 loop
                  if Pair then
                     declare
                        A : constant Long_Long_Integer := Got (1) (K);
                        B : constant Long_Long_Integer := Got (2) (K);
                        Sum : constant Long_Long_Integer := 2 * A + B mod 2;
                     begin
                        case Choice is
                           when 0 => Output (1) (First + K) := A; Output (2) (First + K) := B;
                           when 1 => Output (1) (First + K) := A; Output (2) (First + K) := A - B;
                           when 2 => Output (1) (First + K) := A + B; Output (2) (First + K) := B;
                           when others => Output (1) (First + K) := (Sum + B) / 2; Output (2) (First + K) := (Sum - B) / 2;
                        end case;
                     end;
                  else
                     for C in 1 .. Channels loop
                        Output (C) (First + K) := Got (C) (K);
                     end loop;
                  end if;
               end loop;
            end;
         end loop;
         Same := Same and then Offset = Length;
         for C in 1 .. Channels loop
            for I in 0 .. Frames - 1 loop
               declare
                  V : constant Long_Long_Integer :=
                    (if Mode (C) = 1 then From_Integer (Output (C) (I), Scale (C)) else Output (C) (I));
                  Original : constant Long_Long_Integer :=
                    (if Mode (C) = 1 then From_Integer (Input.Samples (C) (I), Scale (C)) else Input.Samples (C) (I));
               begin
                  Same := Same and then V = Original;
               end;
            end loop;
         end loop;
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
      Put_Line (", delay" & Kinds (6)'Image & ", tiers" & Kinds (7)'Image & ", LPC" & Kinds (8)'Image & "; Rice" & Kinds (9)'Image
                & ", run-length" & Kinds (10)'Image
                & (if Input.Is_Float then "; float as " & (if Mode (1) = 1 then "integers / 2**" & Scale (1)'Image else "ordered bits") else ""));
      if Pair then
         Put ("    stereo:");
         for M in 0 .. 3 loop
            Put (" " & Mode_Names (M) (1 .. (if M = 3 then 8 elsif M = 1 then 9 else 10)) & Stereo (M)'Image & (if M < 3 then "," else ""));
         end loop;
         New_Line;
      end if;
   end;
end Codec_Main;
