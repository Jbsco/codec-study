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
with Interfaces; use Interfaces;
with Bit_Streams; use Bit_Streams;
with Block_Codec; use Block_Codec;
with Checksums;
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
      Real_Text.Put (Value, Fore => 4, Aft => Aft, Exp => 0);
   end Put_Real;

   type Kind_Counts is array (0 .. 11) of Natural;

   --  Bits of the coded blocks by role, and two estimates for LPC blocks: the coefficients in the better of Rice
   --  and Exp-Golomb codes with a per-block parameter, and the warm-up coded at the block's residual rate.
   type Side_Counts is record
      Headers, Coefficients, Warm_Up, Tables, Residuals, Coded_Coefficients, Seeded_Warm_Up : Long_Long_Integer := 0;
   end record;

   function Bits_Of_Length (U : Unsigned_64) return Natural is
      L : Natural := 0;
   begin
      while Shift_Right (U, L) /= 0 loop
         L := L + 1;
      end loop;
      return L;
   end Bits_Of_Length;

   --  Count the coding of the Size-byte block at byte Offset: constant, predictor 0 to 7, then Rice or run-length
   --  codes, and add its bits by role to Side.
   procedure Count_Kind (Stream : Byte_Array; Offset, Size, Samples : Natural; Kinds : in out Kind_Counts; Side : in out Side_Counts) is
      Kind_Pos : Natural := Offset * 8;
      Field : Unsigned_64;
      Coefficient_Bits, Warm_Bits, Order_Of : Long_Long_Integer := 0;
      Coded : Long_Long_Integer := 0;
      Table_At : Natural;
   begin
      Get (Stream, Kind_Pos, Field, 1);
      if Field = 0 then
         Kinds (0) := Kinds (0) + 1;
         Side.Headers := Side.Headers + Long_Long_Integer (8 * Size);
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
            Order, Precision, K, Bit, Value : Unsigned_64;
            Values : array (1 .. 32) of Unsigned_64 := [others => 0];
            Warm_Start : Natural;
         begin
            Get (Stream, Kind_Pos, Order, 5);
            Get (Stream, Kind_Pos, Precision, 4);
            Kind_Pos := Kind_Pos + 5;
            for J in 1 .. Natural (Order) + 1 loop
               Get (Stream, Kind_Pos, Value, Natural (Precision) + 1);
               declare
                  Q : constant Long_Long_Integer :=
                    (if Value >= 2**Natural (Precision) then Long_Long_Integer (Value) - 2**(Natural (Precision) + 1) else Long_Long_Integer (Value));
               begin
                  Values (J) := (if Q >= 0 then Unsigned_64 (2 * Q) else Unsigned_64 (-(2 * Q) - 1));
               end;
            end loop;
            Order_Of := Long_Long_Integer (Order) + 1;
            Coefficient_Bits := Order_Of * (Long_Long_Integer (Precision) + 1);
            Get (Stream, Kind_Pos, Value, 1);
            if Value = 1 then
               Kind_Pos := Kind_Pos + 4;
               Kinds (11) := Kinds (11) + 1;
            end if;
            Coded := Long_Long_Integer'Last;
            for P in 0 .. 15 loop
               declare
                  Rice, Golomb : Long_Long_Integer := 5;
               begin
                  for J in 1 .. Natural (Order) + 1 loop
                     Rice := Rice + Long_Long_Integer (Shift_Right (Values (J), P)) + 1 + Long_Long_Integer (P);
                     Golomb := Golomb + Long_Long_Integer (2 * Bits_Of_Length (Shift_Right (Values (J), P) + 1) - 1 + P);
                  end loop;
                  Coded := Long_Long_Integer'Min (Coded, Long_Long_Integer'Min (Rice, Golomb));
               end;
            end loop;
            Warm_Start := Kind_Pos;
            if Value = 0 then
               Get (Stream, Kind_Pos, K, 6);
               for Unused in 0 .. Order loop
                  loop
                     Get (Stream, Kind_Pos, Bit, 1);
                     exit when Bit = 1;
                  end loop;
                  Kind_Pos := Kind_Pos + Natural (K);
               end loop;
            end if;
            Warm_Bits := Long_Long_Integer (Kind_Pos - Warm_Start);
         end;
      end if;
      Get (Stream, Kind_Pos, Field, 1);
      Kinds (9 + Natural (Field)) := Kinds (9 + Natural (Field)) + 1;
      Table_At := Kind_Pos;
      if Field = 0 then
         Kind_Pos := Kind_Pos + 6;
      else
         declare
            M, Bit, Rest : Unsigned_64;
            Zeros : Natural;
         begin
            Get (Stream, Kind_Pos, M, 11);
            for Unused in 1 .. M loop
               Zeros := 0;
               loop
                  Get (Stream, Kind_Pos, Bit, 1);
                  exit when Bit = 1;
                  Zeros := Zeros + 1;
               end loop;
               Get (Stream, Kind_Pos, Rest, Zeros);
               Kind_Pos := Kind_Pos + 5;
            end loop;
         end;
      end if;
      declare
         Header_Bits : constant Long_Long_Integer :=
           Long_Long_Integer (Table_At - Offset * 8) - Coefficient_Bits - Warm_Bits;
         Table_Bits : constant Long_Long_Integer := Long_Long_Integer (Kind_Pos - Table_At);
         Residual_Bits : constant Long_Long_Integer := Long_Long_Integer (8 * Size + Offset * 8 - Kind_Pos);
      begin
         Side.Headers := Side.Headers + Header_Bits;
         Side.Coefficients := Side.Coefficients + Coefficient_Bits;
         Side.Warm_Up := Side.Warm_Up + Warm_Bits;
         Side.Tables := Side.Tables + Table_Bits;
         Side.Residuals := Side.Residuals + Residual_Bits;
         if Order_Of > 0 then
            Side.Coded_Coefficients := Side.Coded_Coefficients + Coded;
            Side.Seeded_Warm_Up := Side.Seeded_Warm_Up + Order_Of * Residual_Bits / Long_Long_Integer (Samples - Natural (Order_Of));
         end if;
      end;
   end Count_Kind;

   --  V divided by two, rounded down.
   function Half_Down (V : Long_Long_Integer) return Long_Long_Integer is (if V >= 0 then V / 2 else -((1 - V) / 2));

   --  The two signals each stereo mode codes: left and right, left and side, side and right, mid and side, where
   --  signals 1 and 2 are the channels, 3 is the mid and 4 the side.
   Mode_Signals : constant array (0 .. 3, 1 .. 2) of Positive := [[1, 2], [1, 4], [4, 2], [3, 4]];
   Mode_Names : constant array (0 .. 3) of String (1 .. 10) := ["left/right", "left/side ", "side/right", "mid/side  "];

   --  Each group of 4096 frames splits into blocks of 4096, 2048, 1024 or 512 frames.
   Top : constant := 3;

   --  The search at each level: the deepest tree level the encoder tries, how it picks a stereo mode (0 left and
   --  right only, 1 by an estimate from second differences, 2 by coding all four signals), and its linear
   --  prediction effort, and whether it tries the adaptive stage. Every level writes the same format.
   type Level_Setting is record
      Deepest, Stereo_Search : Natural;
      Effort : Effort_Type;
   end record;
   Levels : constant array (0 .. 5) of Level_Setting :=
     [(0, 0, (0, 15, False)), (0, 1, (1, 15, False)), (1, 1, (2, 12, False)), (2, 2, (4, 9, False)), (3, 2, (32, 5, False)),
      (3, 2, (32, 5, True))];

   --  The base-2 logarithm of a positive X within 3e-6, as in the block encoder.
   function Log2 (X : Long_Float) return Long_Float is
      T : constant Long_Float := 2.0 * Long_Float'Fraction (X) - 1.0;
   begin
      return Long_Float (Long_Float'Exponent (X) - 1)
        + T * (1.4425347795670296 + T * (-0.7180335903817996 + T * (0.45715812106557047 + T * (-0.2773416459579797
        + T * (0.12147294837882355 + T * (-0.025792345031509872))))));
   end Log2;

   package Byte_IO is new Ada.Direct_IO (Byte);
   Features : Ada.Text_IO.File_Type;
   Writing_Features : Boolean := False;

   --  Integer part of the base-2 logarithm of V plus one, zero for zero: a magnitude in bits.
   function Bits_Of (V : Long_Long_Integer) return Natural is
      B : Natural := 0;
   begin
      while V / 2**B > 0 loop
         B := B + 1;
      end loop;
      return B;
   end Bits_Of;

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

   --  The stream: a header of the magic, version, flags, rate, frames, channels, depth, float flag and float
   --  modes, a counted list of metadata blocks (type, 24-bit length, bytes) and a CRC-16; then the groups, each
   --  a sync word, a 24-bit byte length, its first frame, its frame count, its split tree with a 2-bit stereo
   --  mode per channel pair on each leaf, a 16-bit length and a CRC-16 per block, a CRC-16 of all that, and the
   --  blocks. Blocks read earlier samples only within their segment: every group when the independent flag is
   --  set, otherwise from one seek point to the next.
   Magic : constant Byte_Array (0 .. 3) := [16#42#, 16#4C#, 16#4B#, 16#43#];
   Version : constant := 1;
   Sync : constant := 16#B1C5#;
   Group_Head : constant := 11;
   Tag_Block : constant := 1;
   Seek_Block : constant := 2;
   Max_Pairs : constant := Wav_Files.Max_Channels / 2;
   type Mode_List is array (1 .. Max_Pairs) of Natural;
   type Leaf is record
      First, Count : Natural := 0;
      Modes : Mode_List := [others => 0];
   end record;
   type Leaf_List is array (0 .. 2**Top - 1) of Leaf;
   type Channel_Buffers is array (1 .. Wav_Files.Max_Channels) of Sample_Array_Access;

   Input : Wav_Files.Audio;
begin
   Wav_Files.Read (Ada.Command_Line.Argument (1), 3600, Input);
   if Option ("--features") > 0 then
      Ada.Text_IO.Create (Features, Ada.Text_IO.Out_File, Ada.Command_Line.Argument (Option ("--features") + 1));
      Writing_Features := True;
   end if;
   declare
      Level : constant Natural :=
        (if Ada.Command_Line.Argument_Count >= 2
           and then (Ada.Command_Line.Argument (2)'Length < 2 or else Ada.Command_Line.Argument (2) (1 .. 2) /= "--")
         then Natural'Value (Ada.Command_Line.Argument (2)) else 4);
      Setting : constant Level_Setting := Levels (Level);
      Frames : constant Natural := Input.Frames;
      Channels : constant Natural := Input.Channels;
      Rate : constant Natural := Input.Rate;
      Groups : constant Natural := (Frames + Max_Block - 1) / Max_Block;
      Depth : constant Sample_Bits := (if Input.Is_Float then 32 else Input.Depth);
      Pairs : constant Natural := Channels / 2;
      Signals : constant Natural := Channels + 2 * Pairs;
      Independent : constant Boolean := Option ("--independent") > 0;
      Seek_Every : constant Natural := Option_Value ("--seek-every", 10);
      Table_Span : constant Natural :=
        (if Seek_Every = 0 then 0 else (Seek_Every * (if Rate > 0 then Rate else 44100) + Max_Block - 1) / Max_Block);
      Segment_Span : constant Natural := (if Independent then 1 else Table_Span);
      Entries : constant Natural := (if Table_Span = 0 then 0 else (Groups + Table_Span - 1) / Table_Span);
      Mode : array (1 .. Channels) of Natural := [others => 0];
      Scale : array (1 .. Channels) of Natural := [others => 0];
      Tag_Count, Tag_Bytes, Meta_Count : Natural := 0;
      Tree_Bound : constant Natural := (2**Top + 2 * Pairs * 2**Top) / 8 + 2;
      Group_Bound : constant Natural :=
        Group_Head + Tree_Bound + 4 * Channels * 2**Top + 2 + Channels * (Bound (Max_Block) + 16 * 2**Top);
      Tree : Byte_Array (0 .. Tree_Bound - 1) := [others => 0];
      Group_Blocks : constant Byte_Array_Access := new Byte_Array (0 .. Channels * (Bound (Max_Block) + 16 * 2**Top));
      Data : constant Byte_Array_Access := new Byte_Array (0 .. Groups * Group_Bound);
      Group_Start : array (0 .. Groups - 1) of Natural := [others => 0];
      Sizes : array (0 .. Channels * 2**Top - 1) of Natural := [others => 0];
      Crcs : array (0 .. Channels * 2**Top - 1) of Unsigned_16 := [others => 0];
      Header_Length, Length : Natural := 0;
      Blocks, Data_Length, Framing : Natural := 0;
      Pos : Natural := 0;
      Start : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      Encoded : Ada.Real_Time.Time;
      Same : Boolean := True;
      Hash : Unsigned_64 := 14695981039346656037;
      Kinds : Kind_Counts := [others => 0];
      Side : Side_Counts;
      Stereo : array (0 .. 3) of Natural := [others => 0];
      Leaves : array (0 .. Top) of Natural := [others => 0];
      Signal : array (1 .. Signals) of Sample_Array_Access;
      Signal_Depth : array (1 .. Signals) of Sample_Bits := [others => Depth];
      Coupled : array (1 .. Pairs) of Boolean := [others => False];
      Trial : array (0 .. Top, 0 .. 2**Top - 1, 1 .. Signals) of Byte_Array_Access;
      Stream : Byte_Array_Access;

      --  A node of a group's split tree is whole when it is a smallest block or its second half starts before
      --  the frame Upto.
      function Whole (First, Level, Upto : Natural) return Boolean is
        (Level = Top or else First + Max_Block / 2**(Level + 1) < Upto);

      --  The pair of channel C, 0 for a channel coded alone; signal S of pair P, 1 and 2 its channels, 3 its mid
      --  and 4 its side; and the signal a mode's position K of pair P names.
      function Pair_Of (C : Positive) return Natural is (if C <= 2 * Pairs then (C + 1) / 2 else 0);
      function Pair_Signal (P, S : Positive) return Positive is
        (case S is when 1 => 2 * P - 1, when 2 => 2 * P, when 3 => Channels + 2 * P - 1, when others => Channels + 2 * P);
      function Signal_Of (P : Positive; M : Natural; K : Positive) return Positive is (Pair_Signal (P, Mode_Signals (M, K)));
      function Coded_Signal (C : Positive; Modes : Mode_List) return Positive is
        (if Pair_Of (C) = 0 then C else Signal_Of (Pair_Of (C), Modes (Pair_Of (C)), C - 2 * (Pair_Of (C) - 1)));

      --  The first frame of the segment holding frame F: the group's own first frame when every group is a
      --  segment, else the last seek point at or before it.
      function Segment_First (F : Natural) return Natural is
        (if Segment_Span = 0 then 0 else (F / Max_Block - (F / Max_Block) mod Segment_Span) * Max_Block);

      --  The stereo mode of pair P whose two signals have the least estimated bits: the base-2 logarithms of
      --  their summed absolute second differences, each plus the frame count.
      function Estimated_Mode (First, Last : Natural; P : Positive) return Natural is
         Sums : array (1 .. 4) of Long_Long_Integer := [others => 0];
         Cost : array (0 .. 3) of Long_Float;
         Pick : Natural := 0;
      begin
         for S in 1 .. 4 loop
            for I in First + 2 .. Last loop
               Sums (S) := Sums (S) + abs (Signal (Pair_Signal (P, S)) (I) - 2 * Signal (Pair_Signal (P, S)) (I - 1)
                                           + Signal (Pair_Signal (P, S)) (I - 2));
            end loop;
         end loop;
         for M in 0 .. 3 loop
            Cost (M) := Log2 (Long_Float (Sums (Mode_Signals (M, 1)) + Long_Long_Integer (Last - First + 1)))
              + Log2 (Long_Float (Sums (Mode_Signals (M, 2)) + Long_Long_Integer (Last - First + 1)));
            if Cost (M) < Cost (Pick) then
               Pick := M;
            end if;
         end loop;
         return Pick;
      end Estimated_Mode;

      --  The input sample as the decoder must return it: the integer, or the float's integer scaled back.
      function Original (C : Positive; I : Natural) return Long_Long_Integer is
        (if Mode (C) = 1 then From_Integer (Input.Samples (C) (I), Scale (C)) else Input.Samples (C) (I));
   begin
      for I in 2 .. Ada.Command_Line.Argument_Count - 1 loop
         if Ada.Command_Line.Argument (I) = "--tag" then
            Tag_Count := Tag_Count + 1;
            Tag_Bytes := Tag_Bytes + 2 + Ada.Command_Line.Argument (I + 1)'Length;
         end if;
      end loop;
      Header_Length := 17 + (if Input.Is_Float then 2 * Channels else 0) + 1 + (if Tag_Count > 0 then 4 + Tag_Bytes else 0)
        + (if Entries > 0 then 4 + 12 * Entries else 0) + 2;
      Stream := new Byte_Array (0 .. Header_Length + Data'Length);
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
      for C in 1 .. Channels loop
         Signal (C) := new Sample_Array'(Sample_Array (Input.Samples (C).all));
      end loop;
      for P in 1 .. Pairs loop
         Coupled (P) := Option ("--no-pairs") = 0 and then Mode (2 * P - 1) = Mode (2 * P) and then Scale (2 * P - 1) = Scale (2 * P);
         if Coupled (P) then
            Signal (Pair_Signal (P, 3)) := new Sample_Array (0 .. Frames - 1);
            Signal (Pair_Signal (P, 4)) := new Sample_Array (0 .. Frames - 1);
            for I in 0 .. Frames - 1 loop
               Signal (Pair_Signal (P, 3)) (I) := Half_Down (Signal (2 * P - 1) (I) + Signal (2 * P) (I));
               Signal (Pair_Signal (P, 4)) (I) := Signal (2 * P - 1) (I) - Signal (2 * P) (I);
            end loop;
            Signal_Depth (Pair_Signal (P, 4)) := Depth + 1;
         end if;
      end loop;
      for L in 0 .. Top loop
         for J in 0 .. 2**Top - 1 loop
            for S in 1 .. Signals loop
               Trial (L, J, S) := new Byte_Array (0 .. Bound (Max_Block / 2**L) - 1);
            end loop;
         end loop;
      end loop;

      --  Code every node of each group's tree, keep the cheaper of each node and its halves, then write the
      --  group: its header, its leaves' modes, the block table, the CRC and the blocks.
      for G in 0 .. Groups - 1 loop
         declare
            Group_First : constant Natural := G * Max_Block;
            Group_Count : constant Natural := Natural'Min (Max_Block, Frames - Group_First);
            Upto : constant Natural := Group_First + Group_Count;
            Bytes : array (0 .. Top, 0 .. 2**Top - 1, 1 .. Signals) of Natural := [others => [others => [others => 0]]];
            Choice : array (0 .. Top, 0 .. 2**Top - 1) of Mode_List := [others => [others => [others => 0]]];
            Cost : array (0 .. Top, 0 .. 2**Top - 1) of Natural := [others => [others => 0]];
            Split : array (0 .. Top, 0 .. 2**Top - 1) of Boolean := [others => [others => False]];
            Tree_Pos, Count, Group_Bytes : Natural := 0;

            function First_Of (L, J : Natural) return Natural is (Group_First + J * (Max_Block / 2**L));

            --  The nodes the search codes: the root, the halves of a node above the deepest level searched, and
            --  the first half of a node that is not whole.
            function Needed (L, J : Natural) return Boolean is
              (L = 0 or else (Needed (L - 1, J / 2)
                              and then (not Whole (First_Of (L - 1, J / 2), L - 1, Upto) or else L - 1 < Setting.Deepest)));

            procedure Emit (L, J : Natural) is
            begin
               if not Whole (First_Of (L, J), L, Upto) then
                  Emit (L + 1, 2 * J);
                  return;
               end if;
               if L < Top then
                  Put (Tree, Tree_Pos, Boolean'Pos (Split (L, J)), 1);
                  if Split (L, J) then
                     Emit (L + 1, 2 * J);
                     Emit (L + 1, 2 * J + 1);
                     return;
                  end if;
               end if;
               for P in 1 .. Pairs loop
                  Put (Tree, Tree_Pos, Unsigned_64 (Choice (L, J) (P)), 2);
                  Stereo (Choice (L, J) (P)) := Stereo (Choice (L, J) (P)) + 1;
               end loop;
               Leaves (L) := Leaves (L) + 1;
               for C in 1 .. Channels loop
                  declare
                     S : constant Positive := Coded_Signal (C, Choice (L, J));
                     B : constant Natural := Bytes (L, J, S);
                  begin
                     Group_Blocks (Group_Bytes .. Group_Bytes + B - 1) := Trial (L, J, S) (0 .. B - 1);
                     Count_Kind (Group_Blocks.all, Group_Bytes, B, Natural'Min (First_Of (L, J) + Max_Block / 2**L, Upto) - First_Of (L, J),
                                 Kinds, Side);
                     Sizes (Count) := B;
                     Crcs (Count) := Checksums.Of_Bytes (Trial (L, J, S) (0 .. B - 1));
                     Count := Count + 1;
                     Group_Bytes := Group_Bytes + B;
                  end;
               end loop;
            end Emit;
         begin
            Tree := [others => 0];
            for L in 0 .. Top loop
               for J in 0 .. 2**L - 1 loop
                  if First_Of (L, J) < Upto and then Whole (First_Of (L, J), L, Upto) and then Needed (L, J) then
                     declare
                        First : constant Natural := First_Of (L, J);
                        Last : constant Natural := Natural'Min (First + Max_Block / 2**L, Upto) - 1;
                        From : constant Natural := Natural'Max (Segment_First (First), First - Max_History);
                        Searched : array (1 .. Signals) of Boolean := [others => False];
                     begin
                        for P in 1 .. Pairs loop
                           if Coupled (P) and then Setting.Stereo_Search = 1 then
                              Choice (L, J) (P) := Estimated_Mode (First, Last, P);
                           end if;
                        end loop;
                        for C in 1 .. Channels loop
                           if Pair_Of (C) > 0 and then Coupled (Pair_Of (C)) and then Setting.Stereo_Search = 2 then
                              for S in 1 .. 4 loop
                                 Searched (Pair_Signal (Pair_Of (C), S)) := True;
                              end loop;
                           else
                              Searched (Coded_Signal (C, Choice (L, J))) := True;
                           end if;
                        end loop;
                        for S in 1 .. Signals loop
                           if Searched (S) then
                              Encode (Signal (S) (First .. Last), Signal (S) (From .. First - 1), Signal_Depth (S), Setting.Effort,
                                      Trial (L, J, S).all, Bytes (L, J, S));
                           end if;
                        end loop;
                        for P in 1 .. Pairs loop
                           if Coupled (P) and then Setting.Stereo_Search = 2 then
                              for M in 1 .. 3 loop
                                 if Bytes (L, J, Signal_Of (P, M, 1)) + Bytes (L, J, Signal_Of (P, M, 2))
                                   < Bytes (L, J, Signal_Of (P, Choice (L, J) (P), 1)) + Bytes (L, J, Signal_Of (P, Choice (L, J) (P), 2))
                                 then
                                    Choice (L, J) (P) := M;
                                 end if;
                              end loop;
                           end if;
                        end loop;
                        Cost (L, J) := 32 * Channels + 2 * Pairs;
                        for C in 1 .. Channels loop
                           Cost (L, J) := Cost (L, J) + 8 * Bytes (L, J, Coded_Signal (C, Choice (L, J)));
                        end loop;
                     end;
                  end if;
               end loop;
            end loop;
            for L in reverse 0 .. Top - 1 loop
               for J in 0 .. 2**L - 1 loop
                  if First_Of (L, J) < Upto and then Needed (L, J) then
                     if not Whole (First_Of (L, J), L, Upto) then
                        Cost (L, J) := Cost (L + 1, 2 * J);
                     elsif L < Setting.Deepest and then 1 + Cost (L + 1, 2 * J) + Cost (L + 1, 2 * J + 1) < 1 + Cost (L, J) then
                        Split (L, J) := True;
                        Cost (L, J) := 1 + Cost (L + 1, 2 * J) + Cost (L + 1, 2 * J + 1);
                     else
                        Cost (L, J) := 1 + Cost (L, J);
                     end if;
                  end if;
               end loop;
            end loop;
            Emit (0, 0);
            --  Features of the group's first channel: bits of the summed absolute first differences of each
            --  eighth, bits of the peak sample, and the frames; then the label, whether the root was split.
            if Writing_Features and then Group_Count = Max_Block then
               declare
                  Peak : Long_Long_Integer := 0;
               begin
                  for Eighth in 0 .. 7 loop
                     declare
                        Sum : Long_Long_Integer := 0;
                        From : constant Natural := Group_First + Eighth * (Max_Block / 8);
                     begin
                        for I in From + 1 .. From + Max_Block / 8 - 1 loop
                           Sum := Sum + abs (Signal (1) (I) - Signal (1) (I - 1));
                           Peak := Long_Long_Integer'Max (Peak, abs Signal (1) (I));
                        end loop;
                        Ada.Text_IO.Put (Features, Natural'Image (Bits_Of (Sum)));
                     end;
                  end loop;
                  Ada.Text_IO.Put (Features, Natural'Image (Bits_Of (Peak)) & Natural'Image (Boolean'Pos (Split (0, 0))));
                  Ada.Text_IO.New_Line (Features);
               end;
            end if;
            Put (Tree, Tree_Pos, 0, (8 - Tree_Pos mod 8) mod 8);
            declare
               Tree_Bytes : constant Natural := Tree_Pos / 8;
               Head_Bytes : constant Natural := Group_Head + Tree_Bytes + 4 * Count + 2;
               Group_Length : constant Natural := Head_Bytes + Group_Bytes;
               P : Natural := Data_Length * 8;
            begin
               Group_Start (G) := Data_Length;
               Put (Data.all, P, Sync, 16);
               Put (Data.all, P, Unsigned_64 (Group_Length), 24);
               Put (Data.all, P, Unsigned_64 (Group_First), 32);
               Put (Data.all, P, Unsigned_64 (Group_Count), 16);
               Data (P / 8 .. P / 8 + Tree_Bytes - 1) := Tree (0 .. Tree_Bytes - 1);
               P := P + 8 * Tree_Bytes;
               for I in 0 .. Count - 1 loop
                  Put (Data.all, P, Unsigned_64 (Sizes (I)), 16);
                  Put (Data.all, P, Unsigned_64 (Crcs (I)), 16);
               end loop;
               Put (Data.all, P, Unsigned_64 (Checksums.Of_Bytes (Data (Data_Length .. P / 8 - 1))), 16);
               Data (P / 8 .. P / 8 + Group_Bytes - 1) := Group_Blocks (0 .. Group_Bytes - 1);
               Data_Length := Data_Length + Group_Length;
               Framing := Framing + Head_Bytes;
               Blocks := Blocks + Count;
            end;
         end;
      end loop;
      if Writing_Features then
         Ada.Text_IO.Close (Features);
      end if;

      --  The header, then the groups.
      Stream (0 .. 3) := Magic;
      Pos := 32;
      Put (Stream.all, Pos, Version, 8);
      Put (Stream.all, Pos, Boolean'Pos (Independent), 8);
      Put (Stream.all, Pos, Unsigned_64 (Rate), 32);
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
      Meta_Count := (if Tag_Count > 0 then 1 else 0) + (if Entries > 0 then 1 else 0);
      Put (Stream.all, Pos, Unsigned_64 (Meta_Count), 8);
      if Tag_Count > 0 then
         Put (Stream.all, Pos, Tag_Block, 8);
         Put (Stream.all, Pos, Unsigned_64 (Tag_Bytes), 24);
         for I in 2 .. Ada.Command_Line.Argument_Count - 1 loop
            if Ada.Command_Line.Argument (I) = "--tag" then
               declare
                  Text : constant String := Ada.Command_Line.Argument (I + 1);
               begin
                  Put (Stream.all, Pos, Unsigned_64 (Text'Length), 16);
                  for Ch of Text loop
                     Put (Stream.all, Pos, Unsigned_64 (Character'Pos (Ch)), 8);
                  end loop;
               end;
            end if;
         end loop;
      end if;
      if Entries > 0 then
         Put (Stream.all, Pos, Seek_Block, 8);
         Put (Stream.all, Pos, Unsigned_64 (12 * Entries), 24);
         for E in 0 .. Entries - 1 loop
            Put (Stream.all, Pos, Unsigned_64 (E * Table_Span * Max_Block), 32);
            Put (Stream.all, Pos, Unsigned_64 (Header_Length + Group_Start (E * Table_Span)), 64);
         end loop;
      end if;
      Put (Stream.all, Pos, Unsigned_64 (Checksums.Of_Bytes (Stream (0 .. Pos / 8 - 1))), 16);
      pragma Assert (Pos / 8 = Header_Length);
      Stream (Header_Length .. Header_Length + Data_Length - 1) := Data (0 .. Data_Length - 1);
      Length := Header_Length + Data_Length;
      Encoded := Ada.Real_Time.Clock;
      Write_Stream (Stream (0 .. Length - 1));
      for B of Stream (0 .. Length - 1) loop
         Hash := (Hash xor Unsigned_64 (B)) * 1099511628211;
      end loop;
      if Option ("--flip") > 0 and then Option ("--flip") + 2 <= Ada.Command_Line.Argument_Count then
         declare
            G : constant Natural := Natural'Value (Ada.Command_Line.Argument (Option ("--flip") + 1));
            K : constant Natural := Natural'Value (Ada.Command_Line.Argument (Option ("--flip") + 2));
            P : constant Natural := Header_Length + Group_Start (G) + K;
         begin
            Stream (P) := Stream (P) xor 16#80#;
         end;
      end if;

      --  Read the header, then every group in turn, finding the next group's sync word again after a damaged
      --  one; then decode the groups of the frame "--seek" names from its seek point alone.
      declare
         Decode_Start : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
         Output, Got : Channel_Buffers;
         Derived : constant Sample_Array_Access := new Sample_Array (0 .. Max_History - 1);
         Status : Status_Type;
         Used : Natural;
         Bad_Crcs, Bad_Groups, Lost_Frames, Wrong, Seek_Count, Tags, First_Group : Natural := 0;
         Lost : array (0 .. Frames - 1) of Boolean := [others => False];
         Seek_Frames, Seek_Offsets : array (0 .. Entries) of Natural := [others => 0];
         Independent_Flag, Decoded_Ok : Boolean := True;
         Tag_Text : Ada.Strings.Unbounded.Unbounded_String;
         Decoded : Ada.Real_Time.Time;

         procedure Read_Header is
            Field : Unsigned_64;
            Count, Kind, Len : Natural;
            Ok : Boolean := Stream (0 .. 3) = Magic;
         begin
            Pos := 32;
            Get (Stream.all, Pos, Field, 8);
            Ok := Ok and then Field = Version;
            Get (Stream.all, Pos, Field, 8);
            Independent_Flag := Field = 1;
            Get (Stream.all, Pos, Field, 32);
            Ok := Ok and then Field = Unsigned_64 (Rate);
            Get (Stream.all, Pos, Field, 32);
            Ok := Ok and then Field = Unsigned_64 (Frames);
            Get (Stream.all, Pos, Field, 8);
            Ok := Ok and then Field = Unsigned_64 (Channels);
            Get (Stream.all, Pos, Field, 8);
            Ok := Ok and then Field = Unsigned_64 (Input.Depth);
            Get (Stream.all, Pos, Field, 8);
            Ok := Ok and then Field = Boolean'Pos (Input.Is_Float);
            if Input.Is_Float then
               for C in 1 .. Channels loop
                  Get (Stream.all, Pos, Field, 8);
                  Ok := Ok and then Field = Unsigned_64 (Mode (C));
                  Get (Stream.all, Pos, Field, 8);
                  Ok := Ok and then Field = Unsigned_64 (Scale (C));
               end loop;
            end if;
            Get (Stream.all, Pos, Field, 8);
            Count := Natural (Field);
            for B in 1 .. Count loop
               Get (Stream.all, Pos, Field, 8);
               Kind := Natural (Field);
               Get (Stream.all, Pos, Field, 24);
               Len := Natural (Field);
               if Kind = Tag_Block then
                  declare
                     Q : Natural := Pos;
                  begin
                     while Q < Pos + 8 * Len loop
                        Get (Stream.all, Q, Field, 16);
                        Tags := Tags + 1;
                        Ada.Strings.Unbounded.Append (Tag_Text, (if Tags > 1 then ", " else ""));
                        for K in 1 .. Natural (Field) loop
                           declare
                              Ch : Unsigned_64;
                           begin
                              Get (Stream.all, Q, Ch, 8);
                              Ada.Strings.Unbounded.Append (Tag_Text, Character'Val (Ch));
                           end;
                        end loop;
                     end loop;
                  end;
               elsif Kind = Seek_Block then
                  for E in 1 .. Len / 12 loop
                     Get (Stream.all, Pos, Field, 32);
                     Seek_Frames (Seek_Count) := Natural (Field);
                     Get (Stream.all, Pos, Field, 64);
                     Seek_Offsets (Seek_Count) := Natural (Field);
                     Seek_Count := Seek_Count + 1;
                  end loop;
                  Pos := Pos - 96 * (Len / 12);
               end if;
               Pos := Pos + 8 * Len;
            end loop;
            Ok := Ok and then Checksums.Matches (Stream.all, Pos / 8, Checksums.Of_Bytes (Stream (0 .. Pos / 8 - 1)));
            Pos := Pos + 16;
            First_Group := Pos / 8;
            Same := Same and then Ok;
         end Read_Header;

         --  The group header at Offset: its byte length, first frame, frame count, leaves and the position of
         --  its block table. Ok when the sync word, the fields and the CRC are all right.
         procedure Parse_Group (Offset : Natural; Group_Length, Group_First, Group_Count : out Natural; L : out Leaf_List;
                                Leaf_Count, Table_At : out Natural; Ok : out Boolean) is
            Field : Unsigned_64;
            P : Natural := Offset * 8;

            procedure Walk (First, Level : Natural) is
            begin
               if not Whole (First, Level, Group_First + Group_Count) then
                  Walk (First, Level + 1);
                  return;
               end if;
               if Level < Top then
                  Get (Stream.all, P, Field, 1);
                  if Field = 1 then
                     Walk (First, Level + 1);
                     Walk (First + Max_Block / 2**(Level + 1), Level + 1);
                     return;
                  end if;
               end if;
               L (Leaf_Count).First := First;
               L (Leaf_Count).Count := Natural'Min (First + Max_Block / 2**Level, Group_First + Group_Count) - First;
               for Pr in 1 .. Pairs loop
                  Get (Stream.all, P, Field, 2);
                  L (Leaf_Count).Modes (Pr) := Natural (Field);
               end loop;
               Leaf_Count := Leaf_Count + 1;
            end Walk;
         begin
            Ok := False;
            Leaf_Count := 0;
            Table_At := 0;
            Group_Length := 0;
            Group_First := 0;
            Group_Count := 0;
            L := [others => (0, 0, [others => 0])];
            if Offset + Group_Head + 2 > Length then
               return;
            end if;
            Get (Stream.all, P, Field, 16);
            if Field /= Sync then
               return;
            end if;
            Get (Stream.all, P, Field, 24);
            Group_Length := Natural (Field);
            Get (Stream.all, P, Field, 32);
            if Field > Unsigned_64 (Frames) then
               return;
            end if;
            Group_First := Natural (Field);
            Get (Stream.all, P, Field, 16);
            Group_Count := Natural (Field);
            if Group_Length < Group_Head + 2 or else Offset + Group_Length > Length or else Group_Count = 0
              or else Group_Count > Max_Block or else Group_First + Group_Count > Frames
            then
               return;
            end if;
            Walk (Group_First, 0);
            P := (P + 7) / 8 * 8;
            Table_At := P / 8;
            if Table_At + 4 * Leaf_Count * Channels + 2 > Offset + Group_Length then
               return;
            end if;
            P := P + 32 * Leaf_Count * Channels;
            Ok := Checksums.Matches (Stream.all, P / 8, Checksums.Of_Bytes (Stream (Offset .. P / 8 - 1)));
         end Parse_Group;

         --  Decode the group at Offset into Buf, reading earlier samples back to frame Floor at most. Ok when
         --  the header was right and the blocks filled the group exactly; a block whose CRC fails is counted
         --  and decoded anyway.
         procedure Decode_Group (Offset : Natural; Buf : in out Channel_Buffers; Floor : Natural;
                                 Group_Length, Group_First, Group_Count : out Natural; Ok : out Boolean) is
            L : Leaf_List;
            Leaf_Count, Table_At : Natural;
            Field : Unsigned_64;
         begin
            Parse_Group (Offset, Group_Length, Group_First, Group_Count, L, Leaf_Count, Table_At, Ok);
            if not Ok then
               return;
            end if;
            declare
               P : Natural := Table_At * 8;
               Block_At : Natural := Table_At + 4 * Leaf_Count * Channels + 2;
            begin
               for I in 0 .. Leaf_Count - 1 loop
                  declare
                     First : constant Natural := L (I).First;
                     Size_Of : constant Natural := L (I).Count;
                     From : constant Natural := Natural'Max (Floor, First - Max_History);
                  begin
                     for C in 1 .. Channels loop
                        declare
                           S : constant Positive := Coded_Signal (C, L (I).Modes);
                           Size : Natural;
                        begin
                           Get (Stream.all, P, Field, 16);
                           Size := Natural (Field);
                           if Block_At + Size > Offset + Group_Length then
                              Ok := False;
                              return;
                           end if;
                           if not Checksums.Matches (Stream.all, P / 8, Checksums.Of_Bytes (Stream (Block_At .. Block_At + Size - 1))) then
                              Bad_Crcs := Bad_Crcs + 1;
                           end if;
                           P := P + 16;
                           if S <= Channels then
                              Decode (Stream (Block_At .. Block_At + Size - 1), Buf (S) (From .. First - 1), Signal_Depth (S),
                                      Got (C) (0 .. Size_Of - 1), Used, Status);
                           else
                              declare
                                 A : constant Positive := 2 * Pair_Of (C) - 1;
                              begin
                                 for K in From .. First - 1 loop
                                    Derived (K - From) :=
                                      (if S = Pair_Signal (Pair_Of (C), 3) then Half_Down (Buf (A) (K) + Buf (A + 1) (K))
                                       else Buf (A) (K) - Buf (A + 1) (K));
                                 end loop;
                                 Decode (Stream (Block_At .. Block_At + Size - 1), Derived (0 .. First - From - 1), Signal_Depth (S),
                                         Got (C) (0 .. Size_Of - 1), Used, Status);
                              end;
                           end if;
                           Decoded_Ok := Decoded_Ok and then Status = Success and then Used = Size;
                           Block_At := Block_At + Size;
                        end;
                     end loop;
                     for K in 0 .. Size_Of - 1 loop
                        for Pr in 1 .. Pairs loop
                           declare
                              A : constant Long_Long_Integer := Got (2 * Pr - 1) (K);
                              B : constant Long_Long_Integer := Got (2 * Pr) (K);
                              Sum : constant Long_Long_Integer := 2 * A + B mod 2;
                           begin
                              case L (I).Modes (Pr) is
                                 when 0 => Buf (2 * Pr - 1) (First + K) := A; Buf (2 * Pr) (First + K) := B;
                                 when 1 => Buf (2 * Pr - 1) (First + K) := A; Buf (2 * Pr) (First + K) := A - B;
                                 when 2 => Buf (2 * Pr - 1) (First + K) := A + B; Buf (2 * Pr) (First + K) := B;
                                 when others => Buf (2 * Pr - 1) (First + K) := (Sum + B) / 2; Buf (2 * Pr) (First + K) := (Sum - B) / 2;
                              end case;
                           end;
                        end loop;
                        for C in 2 * Pairs + 1 .. Channels loop
                           Buf (C) (First + K) := Got (C) (K);
                        end loop;
                     end loop;
                  end;
               end loop;
               Ok := Block_At = Offset + Group_Length;
            end;
         end Decode_Group;

         --  The first offset at or after From that starts a group with a right header, or Length.
         function Next_Sync (From : Natural) return Natural is
            L : Leaf_List;
            A, B, C, N, T : Natural;
            Ok : Boolean;
         begin
            for P in From .. Length - Group_Head - 2 loop
               if Natural (Stream (P)) * 256 + Natural (Stream (P + 1)) = Sync then
                  Parse_Group (P, A, B, C, L, N, T, Ok);
                  if Ok then
                     return P;
                  end if;
               end if;
            end loop;
            return Length;
         end Next_Sync;
      begin
         Read_Header;
         for C in 1 .. Channels loop
            Output (C) := new Sample_Array'(0 .. Frames - 1 => 0);
            Got (C) := new Sample_Array (0 .. Max_Block - 1);
         end loop;
         declare
            Offset : Natural := First_Group;
            Expected : Natural := 0;
            Group_Length, Group_First, Group_Count, Leaf_Count, Table_At : Natural;
            L : Leaf_List;
            Ok : Boolean;
         begin
            while Offset < Length loop
               Decode_Group (Offset, Output, 0, Group_Length, Group_First, Group_Count, Ok);
               if Ok and then Group_First = Expected then
                  Offset := Offset + Group_Length;
                  Expected := Group_First + Group_Count;
               else
                  Bad_Groups := Bad_Groups + 1;
                  Offset := Next_Sync (Offset + 1);
                  if Offset < Length then
                     Parse_Group (Offset, Group_Length, Group_First, Group_Count, L, Leaf_Count, Table_At, Ok);
                     if Group_First > Expected then
                        Lost_Frames := Lost_Frames + Group_First - Expected;
                        Lost (Expected .. Group_First - 1) := [others => True];
                     end if;
                     Expected := Group_First;
                  else
                     Lost_Frames := Lost_Frames + Frames - Expected;
                     Lost (Expected .. Frames - 1) := [others => True];
                  end if;
               end if;
            end loop;
            Same := Same and then Decoded_Ok and then Expected = Frames and then Bad_Groups = 0 and then Bad_Crcs = 0;
         end;
         for C in 1 .. Channels loop
            for I in 0 .. Frames - 1 loop
               if not Lost (I) and then (if Mode (C) = 1 then From_Integer (Output (C) (I), Scale (C)) else Output (C) (I)) /= Original (C, I) then
                  Wrong := Wrong + 1;
               end if;
            end loop;
         end loop;
         Same := Same and then Wrong = 0 and then Lost_Frames = 0;
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
                   & ", run-length" & Kinds (10)'Image & "; adaptive stage" & Kinds (11)'Image
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
                      else "a segment every" & Segment_Span'Image & " groups") & "," & Seek_Count'Image & " seek points"
                   & (if Tags > 0 then "; tags " & Ada.Strings.Unbounded.To_String (Tag_Text) else ""));
         if Bad_Groups > 0 or else Bad_Crcs > 0 or else Wrong > 0 then
            Put_Line ("    damage:" & Bad_Groups'Image & " groups failed," & Bad_Crcs'Image & " block CRCs failed," & Lost_Frames'Image
                      & " frames lost," & Wrong'Image & " samples wrong outside them" & (if Wrong = 0 then "; damage contained" else ""));
         end if;

         if Option ("--seek") > 0 then
            declare
               Target : constant Natural := Natural'Min (Option_Value ("--seek", 0), Frames - 1);
               Buf : Channel_Buffers;
               Offset : Natural := First_Group;
               Floor, Hops, Count : Natural := 0;
               Group_Length, Group_First, Group_Count, Leaf_Count, Table_At : Natural := 0;
               L : Leaf_List;
               Ok : Boolean := True;
               Seek_Same : Boolean := True;
            begin
               for E in 0 .. Seek_Count - 1 loop
                  if Seek_Frames (E) <= Target then
                     Offset := Seek_Offsets (E);
                     Floor := Seek_Frames (E);
                  end if;
               end loop;
               if Independent_Flag then
                  loop
                     Parse_Group (Offset, Group_Length, Group_First, Group_Count, L, Leaf_Count, Table_At, Ok);
                     exit when not Ok or else Group_First + Group_Count > Target;
                     Offset := Offset + Group_Length;
                     Hops := Hops + 1;
                  end loop;
                  Floor := Group_First;
               end if;
               for C in 1 .. Channels loop
                  Buf (C) := new Sample_Array'(0 .. Frames - 1 => 0);
               end loop;
               while Ok loop
                  Decode_Group (Offset, Buf, Floor, Group_Length, Group_First, Group_Count, Ok);
                  exit when not Ok;
                  Count := Count + 1;
                  Offset := Offset + Group_Length;
                  exit when Group_First + Group_Count > Target;
               end loop;
               if Ok then
                  for C in 1 .. Channels loop
                     for I in Target .. Group_First + Group_Count - 1 loop
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
