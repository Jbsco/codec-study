--  Code a WAV file with the block codec, decode it again and compare every sample. Prints the size, a hash of
--  the coded stream, the wall time of each step, and which block coding was chosen how often.
--  Usage: codec_main <file.wav> [level 0 to 4, 4 when left out]
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
            Get (Stream, Kind_Pos, K, 6);
            for Unused in 0 .. Order loop
               loop
                  Get (Stream, Kind_Pos, Bit, 1);
                  exit when Bit = 1;
               end loop;
               Kind_Pos := Kind_Pos + Natural (K);
            end loop;
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
   --  prediction effort. Every level writes the same format.
   type Level_Setting is record
      Deepest, Stereo_Search : Natural;
      Effort : Effort_Type;
   end record;
   Levels : constant array (0 .. 4) of Level_Setting :=
     [(0, 0, (0, 15)), (0, 1, (1, 15)), (1, 1, (2, 12)), (2, 2, (4, 9)), (3, 2, (32, 5))];

   --  The base-2 logarithm of a positive X within 3e-6, as in the block encoder.
   function Log2 (X : Long_Float) return Long_Float is
      T : constant Long_Float := 2.0 * Long_Float'Fraction (X) - 1.0;
   begin
      return Long_Float (Long_Float'Exponent (X) - 1)
        + T * (1.4425347795670296 + T * (-0.7180335903817996 + T * (0.45715812106557047 + T * (-0.2773416459579797
        + T * (0.12147294837882355 + T * (-0.025792345031509872))))));
   end Log2;

   Input : Wav_Files.Audio;
begin
   Wav_Files.Read (Ada.Command_Line.Argument (1), 3600, Input);
   declare
      Level : constant Natural := (if Ada.Command_Line.Argument_Count >= 2 then Natural'Value (Ada.Command_Line.Argument (2)) else 4);
      Setting : constant Level_Setting := Levels (Level);
      Frames : constant Natural := Input.Frames;
      Channels : constant Natural := Input.Channels;
      Groups : constant Natural := (Frames + Max_Block - 1) / Max_Block;
      Depth : constant Sample_Bits := (if Input.Is_Float then 32 else Input.Depth);
      Pair : constant Boolean := Channels = 2;
      Mode : array (1 .. Channels) of Natural := [others => 0];
      Scale : array (1 .. Channels) of Natural := [others => 0];
      Index_At : constant Natural := 7 + (if Input.Is_Float then 2 * Channels else 0);
      Most_Blocks : constant Natural := Channels * Groups * 2**Top;
      Index : constant Byte_Array_Access := new Byte_Array (0 .. 4 * Groups + 8);
      Data : constant Byte_Array_Access := new Byte_Array (0 .. Channels * Groups * (Bound (Max_Block) + 16 * 2**Top));
      Stream : constant Byte_Array_Access := new Byte_Array (0 .. Index_At + Index'Length + 2 * Most_Blocks + Data'Length);
      Sizes : array (0 .. Most_Blocks - 1) of Natural := [others => 0];
      Blocks, Index_Pos, Data_Length, Length : Natural := 0;
      Pos : Natural := 0;
      Start : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      Encoded : Ada.Real_Time.Time;
      Same : Boolean := True;
      Hash : Unsigned_64 := 14695981039346656037;
      Kinds : Kind_Counts := [others => 0];
      Side : Side_Counts;
      Stereo : array (0 .. 3) of Natural := [others => 0];
      Leaves : array (0 .. Top) of Natural := [others => 0];
      Signal : array (1 .. Channels + 2) of Sample_Array_Access;
      Signal_Depth : array (1 .. Channels + 2) of Sample_Bits := [others => Depth];
      Trial : array (0 .. Top, 0 .. 2**Top - 1, 1 .. Channels + 2) of Byte_Array_Access;
      Coupled : Boolean;

      --  A node of a group's split tree is whole when it is a smallest block or its second half starts before the
      --  last frame; otherwise it is the same as its first half and carries no split bit.
      function Whole (First, Level : Natural) return Boolean is (Level = Top or else First + Max_Block / 2**(Level + 1) < Frames);

      --  The stereo mode whose two signals have the least estimated bits: the base-2 logarithms of their summed
      --  absolute second differences, each plus the frame count.
      function Estimated_Mode (First, Last : Natural) return Natural is
         Sums : array (1 .. 4) of Long_Long_Integer := [others => 0];
         Cost : array (0 .. 3) of Long_Float;
         Pick : Natural := 0;
      begin
         for S in 1 .. 4 loop
            for I in First + 2 .. Last loop
               Sums (S) := Sums (S) + abs (Signal (S) (I) - 2 * Signal (S) (I - 1) + Signal (S) (I - 2));
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
      for L in 0 .. Top loop
         for J in 0 .. 2**Top - 1 loop
            for S in 1 .. Channels + 2 loop
               Trial (L, J, S) := new Byte_Array (0 .. Bound (Max_Block / 2**L) - 1);
            end loop;
         end loop;
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

      --  Code every node of each group's tree, keep the cheaper of each node and its halves, then write the leaves.
      for G in 0 .. Groups - 1 loop
         declare
            Bytes : array (0 .. Top, 0 .. 2**Top - 1, 1 .. Channels + 2) of Natural := [others => [others => [others => 0]]];
            Choice, Cost : array (0 .. Top, 0 .. 2**Top - 1) of Natural := [others => [others => 0]];
            Split : array (0 .. Top, 0 .. 2**Top - 1) of Boolean := [others => [others => False]];

            function First_Of (L, J : Natural) return Natural is (G * Max_Block + J * (Max_Block / 2**L));

            --  The nodes the search codes: the root, the halves of a node above the deepest level searched, and
            --  the first half of a node that is not whole.
            function Needed (L, J : Natural) return Boolean is
              (L = 0 or else (Needed (L - 1, J / 2)
                              and then (not Whole (First_Of (L - 1, J / 2), L - 1) or else L - 1 < Setting.Deepest)));

            procedure Emit (L, J : Natural) is
            begin
               if not Whole (First_Of (L, J), L) then
                  Emit (L + 1, 2 * J);
                  return;
               end if;
               if L < Top then
                  Put (Index.all, Index_Pos, Boolean'Pos (Split (L, J)), 1);
                  if Split (L, J) then
                     Emit (L + 1, 2 * J);
                     Emit (L + 1, 2 * J + 1);
                     return;
                  end if;
               end if;
               if Pair then
                  Put (Index.all, Index_Pos, Unsigned_64 (Choice (L, J)), 2);
                  Stereo (Choice (L, J)) := Stereo (Choice (L, J)) + 1;
               end if;
               Leaves (L) := Leaves (L) + 1;
               for C in 1 .. Channels loop
                  declare
                     S : constant Positive := (if Pair then Mode_Signals (Choice (L, J), C) else C);
                     B : constant Natural := Bytes (L, J, S);
                  begin
                     Data (Data_Length .. Data_Length + B - 1) := Trial (L, J, S) (0 .. B - 1);
                     Count_Kind (Data.all, Data_Length, B, Natural'Min (First_Of (L, J) + Max_Block / 2**L, Frames) - First_Of (L, J), Kinds, Side);
                     Sizes (Blocks) := B;
                     Blocks := Blocks + 1;
                     Data_Length := Data_Length + B;
                  end;
               end loop;
            end Emit;
         begin
            for L in 0 .. Top loop
               for J in 0 .. 2**L - 1 loop
                  if First_Of (L, J) < Frames and then Whole (First_Of (L, J), L) and then Needed (L, J) then
                     declare
                        First : constant Natural := First_Of (L, J);
                        Last : constant Natural := Natural'Min (First + Max_Block / 2**L, Frames) - 1;
                        From : constant Natural := Natural'Max (0, First - Max_History);
                     begin
                        if Coupled and then Setting.Stereo_Search = 1 then
                           Choice (L, J) := Estimated_Mode (First, Last);
                        end if;
                        for S in 1 .. (if Coupled and then Setting.Stereo_Search = 2 then 4 else Channels) loop
                           declare
                              Coded : constant Positive :=
                                (if Coupled and then Setting.Stereo_Search = 1 then Mode_Signals (Choice (L, J), S) else S);
                           begin
                              Encode (Signal (Coded) (First .. Last), Signal (Coded) (From .. First - 1), Signal_Depth (Coded),
                                      Setting.Effort, Trial (L, J, Coded).all, Bytes (L, J, Coded));
                           end;
                        end loop;
                        if Coupled and then Setting.Stereo_Search = 2 then
                           for M in 1 .. 3 loop
                              if Bytes (L, J, Mode_Signals (M, 1)) + Bytes (L, J, Mode_Signals (M, 2))
                                < Bytes (L, J, Mode_Signals (Choice (L, J), 1)) + Bytes (L, J, Mode_Signals (Choice (L, J), 2))
                              then
                                 Choice (L, J) := M;
                              end if;
                           end loop;
                        end if;
                        Cost (L, J) := 16 * Channels + (if Pair then 2 else 0);
                        for C in 1 .. Channels loop
                           Cost (L, J) := Cost (L, J) + 8 * Bytes (L, J, (if Pair then Mode_Signals (Choice (L, J), C) else C));
                        end loop;
                     end;
                  end if;
               end loop;
            end loop;
            for L in reverse 0 .. Top - 1 loop
               for J in 0 .. 2**L - 1 loop
                  if First_Of (L, J) < Frames and then Needed (L, J) then
                     if not Whole (First_Of (L, J), L) then
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
         end;
      end loop;
      Put (Index.all, Index_Pos, 0, (8 - Index_Pos mod 8) mod 8);
      Stream (Index_At .. Index_At + Index_Pos / 8 - 1) := Index (0 .. Index_Pos / 8 - 1);
      Pos := (Index_At + Index_Pos / 8) * 8;
      for I in 0 .. Blocks - 1 loop
         Put (Stream.all, Pos, Unsigned_64 (Sizes (I)), 16);
      end loop;
      Length := Pos / 8 + Data_Length;
      Stream (Pos / 8 .. Length - 1) := Data (0 .. Data_Length - 1);
      Encoded := Ada.Real_Time.Clock;

      --  Read the trees back into leaves, then decode the blocks of each leaf in order.
      declare
         Leaf_First, Leaf_Count, Leaf_Mode : array (0 .. Groups * 2**Top - 1) of Natural := [others => 0];
         Count : Natural := 0;
         Bit_Pos : Natural := Index_At * 8;
         Output, Got : array (1 .. Channels) of Sample_Array_Access;
         Derived : constant Sample_Array_Access := new Sample_Array (0 .. Max_History - 1);
         Status : Status_Type;
         Used, Offset, Block : Natural;

         procedure Walk (First, L : Natural) is
            Field : Unsigned_64 := 0;
         begin
            if not Whole (First, L) then
               Walk (First, L + 1);
               return;
            end if;
            if L < Top then
               Get (Stream.all, Bit_Pos, Field, 1);
               if Field = 1 then
                  Walk (First, L + 1);
                  Walk (First + Max_Block / 2**(L + 1), L + 1);
                  return;
               end if;
            end if;
            if Pair then
               Get (Stream.all, Bit_Pos, Field, 2);
            end if;
            Leaf_First (Count) := First;
            Leaf_Count (Count) := Natural'Min (First + Max_Block / 2**L, Frames) - First;
            Leaf_Mode (Count) := Natural (Field);
            Count := Count + 1;
         end Walk;
      begin
         for G in 0 .. Groups - 1 loop
            Walk (G * Max_Block, 0);
         end loop;
         Pos := (Bit_Pos + 7) / 8 * 8;
         Offset := Pos / 8 + 2 * Count * Channels;
         Block := 0;
         for C in 1 .. Channels loop
            Output (C) := new Sample_Array (0 .. Frames - 1);
            Got (C) := new Sample_Array (0 .. Max_Block - 1);
         end loop;
         for Leaf in 0 .. Count - 1 loop
            declare
               First : constant Natural := Leaf_First (Leaf);
               Size_Of : constant Natural := Leaf_Count (Leaf);
               From : constant Natural := Natural'Max (0, First - Max_History);
               Choice : constant Natural := Leaf_Mode (Leaf);
            begin
               for C in 1 .. Channels loop
                  declare
                     S : constant Positive := (if Pair then Mode_Signals (Choice, C) else C);
                     Field : Unsigned_64;
                     Size : Natural;
                  begin
                     Get (Stream.all, Pos, Field, 16);
                     Size := Natural (Field);
                     if S <= Channels then
                        Decode (Stream (Offset .. Offset + Size - 1), Output (S) (From .. First - 1), Signal_Depth (S),
                                Got (C) (0 .. Size_Of - 1), Used, Status);
                     else
                        for I in From .. First - 1 loop
                           Derived (I - From) :=
                             (if S = 3 then Half_Down (Output (1) (I) + Output (2) (I)) else Output (1) (I) - Output (2) (I));
                        end loop;
                        Decode (Stream (Offset .. Offset + Size - 1), Derived (0 .. First - From - 1), Signal_Depth (S),
                                Got (C) (0 .. Size_Of - 1), Used, Status);
                     end if;
                     Same := Same and then Status = Success and then Used = Size;
                     Offset := Offset + Size;
                     Block := Block + 1;
                  end;
               end loop;
               for K in 0 .. Size_Of - 1 loop
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
         Same := Same and then Offset = Length and then Block = Blocks;
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
      Put_Line (" s, level" & Level'Image & "," & Length'Image & " bytes");
      Put ("    blocks: constant" & Kinds (0)'Image & ", orders 0-4");
      for K in 1 .. 5 loop
         Put (Kinds (K)'Image);
      end loop;
      Put_Line (", delay" & Kinds (6)'Image & ", tiers" & Kinds (7)'Image & ", LPC" & Kinds (8)'Image & "; Rice" & Kinds (9)'Image
                & ", run-length" & Kinds (10)'Image
                & (if Input.Is_Float then "; float as " & (if Mode (1) = 1 then "integers / 2**" & Scale (1)'Image else "ordered bits") else ""));
      Put_Line ("    bits: headers" & Side.Headers'Image & ", LPC coefficients" & Side.Coefficients'Image & ", LPC warm-up" & Side.Warm_Up'Image
                & ", code tables" & Side.Tables'Image & ", residuals" & Side.Residuals'Image & ", index and lengths"
                & Long_Long_Integer (Index_Pos + 16 * Blocks)'Image & "; coefficients in Rice or Exp-Golomb codes"
                & Side.Coded_Coefficients'Image & ", warm-up at the residual rate" & Side.Seeded_Warm_Up'Image);
      Put_Line ("    frames per block: 4096" & Leaves (0)'Image & ", 2048" & Leaves (1)'Image & ", 1024" & Leaves (2)'Image
                & ", 512" & Leaves (3)'Image);
      if Pair then
         Put ("    stereo:");
         for M in 0 .. 3 loop
            Put (" " & Mode_Names (M) (1 .. (if M = 3 then 8 elsif M = 1 then 9 else 10)) & Stereo (M)'Image & (if M < 3 then "," else ""));
         end loop;
         New_Line;
      end if;
   end;
end Codec_Main;
