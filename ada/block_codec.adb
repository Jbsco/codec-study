with Interfaces; use Interfaces;
with Canonical_Decoding;

package body Block_Codec with SPARK_Mode is

   Delay_Predictor : constant := 5;
   Tier_Predictor : constant := 6;
   Symbol_Count : constant := 1024;
   End_Of_Block : constant := 0;
   Sixteen_Zeros : constant := 15 * 64;
   Match_Length : constant := 32;
   Longest_Code : constant := 31;

   subtype Width_Bits is Positive range 1 .. 32;
   subtype Sample is Long_Long_Integer range -(2**36) .. 2**36;
   type Sample_Buffer is array (Natural range <>) of Sample;

   type Symbol_Counts is array (0 .. Symbol_Count - 1) of Natural;
   type Code_Table is array (0 .. Symbol_Count - 1) of Unsigned_64;

   function Zigzag (V : Long_Long_Integer) return Unsigned_64 is
     (if V >= 0 then 2 * Unsigned_64 (V) else 2 * Unsigned_64 (-(V + 1)) + 1)
     with Pre => In_Range (V, 40);

   function Magnitude (V : Long_Long_Integer) return Unsigned_64 is
     (if V >= 0 then Unsigned_64 (V) else Unsigned_64 (-(V + 1)) + 1)
     with Pre => In_Range (V, 40);

   function Bit_Length (U : Unsigned_64) return Natural with SPARK_Mode => Off is
      Bits : Natural := 0;
   begin
      for K in 0 .. 63 loop
         if Shift_Right (U, K) /= 0 then
            Bits := K + 1;
         end if;
      end loop;
      return Bits;
   end Bit_Length;

   function Sign_Extend (U : Unsigned_64; Bits : Sample_Bits) return Long_Long_Integer is
     (if U >= Unsigned_64 (Half (Bits)) then Long_Long_Integer (U) - 2 * Half (Bits) else Long_Long_Integer (U))
     with Pre => U < 2**32;

   --  The order-K polynomial prediction of Y (I) from the K samples before it.
   function Fixed_Prediction (Y : Sample_Buffer; I, K : Natural) return Long_Long_Integer is
     (case K is
        when 0 => 0,
        when 1 => Y (I - 1),
        when 2 => 2 * Y (I - 1) - Y (I - 2),
        when 3 => 3 * Y (I - 1) - 3 * Y (I - 2) + Y (I - 3),
        when others => 4 * Y (I - 1) - 6 * Y (I - 2) + 4 * Y (I - 3) - Y (I - 4))
     with Pre => K <= 4 and then K <= I and then I in Y'Range and then Y'First = 0;

   ---------------------------------------------------------------------------------------------------------------
   --  Encoder

   --  The smallest distance P at which the first 32 samples repeat exactly, or zero.
   function Find_Delay (Y : Sample_Buffer) return Natural with SPARK_Mode => Off is
   begin
      for P in 1 .. Y'Length - Match_Length loop
         if (for all J in 0 .. Match_Length - 1 => Y (P + J) = Y (J)) then
            return P;
         end if;
      end loop;
      return 0;
   end Find_Delay;

   --  The final tier, then the offsets of each tier from the coarsest to the finest.
   procedure Tier_Residuals (Y : Sample_Buffer; R : out Sample_Buffer) with SPARK_Mode => Off is
      Cur : Sample_Buffer := Y;
      Last : Natural := Y'Length;
      L : Natural := Y'Length;
   begin
      while L > 2 loop
         declare
            G : constant Natural := L / 2;
         begin
            for J in 0 .. G - 1 loop
               R (Last - G + J) := Cur (2 * J + 1) - (Cur (2 * J) + (if J < G - 1 then Cur (2 * J + 2) else Cur (2 * J))) / 2;
            end loop;
            Last := Last - G;
            for J in 0 .. G - 1 loop
               Cur (J) := Cur (2 * J);
            end loop;
            if L mod 2 = 1 then
               Cur (G) := Cur (L - 1);
            end if;
            L := G + L mod 2;
         end;
      end loop;
      R (0 .. L - 1) := Cur (0 .. L - 1);
   end Tier_Residuals;

   procedure Residuals (Y : Sample_Buffer; Predictor, Delay_Length : Natural; R : out Sample_Buffer)
     with SPARK_Mode => Off
   is
   begin
      case Predictor is
         when 0 .. 4 =>
            for I in Y'Range loop
               R (I) := Y (I) - Fixed_Prediction (Y, I, Natural'Min (Predictor, I));
            end loop;
         when Delay_Predictor =>
            R (0) := Y (0);
            for I in 1 .. Y'Last loop
               R (I) := Y (I) - (if I >= Delay_Length then Y (I - Delay_Length) else Y (I - 1));
            end loop;
         when others =>
            Tier_Residuals (Y, R);
      end case;
   end Residuals;

   --  Walk the Rice parameter up from zero while the cost falls; the cost is convex in the parameter.
   procedure Rice_Cost (R : Sample_Buffer; K : out Natural; Bits : out Unsigned_64) with SPARK_Mode => Off is
      Best : Unsigned_64 := Unsigned_64'Last;
   begin
      K := 0;
      for P in 0 .. 62 loop
         declare
            C : Unsigned_64 := Unsigned_64 (R'Length) * Unsigned_64 (P + 1);
         begin
            for V of R loop
               C := C + Shift_Right (Zigzag (V), P);
            end loop;
            exit when C >= Best;
            Best := C;
            K := P;
         end;
      end loop;
      Bits := Best;
   end Rice_Cost;

   procedure Put_Rice (R : Sample_Buffer; K : Natural; Output : in out Byte_Array; Pos : in out Natural) with SPARK_Mode => Off is
   begin
      Put (Output, Pos, Unsigned_64 (K), 6);
      for V of R loop
         declare
            U : constant Unsigned_64 := Zigzag (V);
            Q : Unsigned_64 := Shift_Right (U, K);
         begin
            while Q > 0 loop
               declare
                  Step : constant Natural := Natural (Unsigned_64'Min (Q, 64));
               begin
                  Put (Output, Pos, 0, Step);
                  Q := Q - Unsigned_64 (Step);
               end;
            end loop;
            Put (Output, Pos, 1, 1);
            Put (Output, Pos, U, K);
         end;
      end loop;
   end Put_Rice;

   --  Elias gamma code of N, at least one: the bit length of N less one in zeros, then N.
   function Gamma_Length (N : Positive) return Natural is (2 * Bit_Length (Unsigned_64 (N)) - 1)
     with SPARK_Mode => Off;

   procedure Put_Gamma (N : Positive; Output : in out Byte_Array; Pos : in out Natural) with SPARK_Mode => Off is
   begin
      Put (Output, Pos, 0, Bit_Length (Unsigned_64 (N)) - 1);
      Put (Output, Pos, Unsigned_64 (N), Bit_Length (Unsigned_64 (N)));
   end Put_Gamma;

   --  Symbols: a run of up to 15 zeros and a bit length, sixteen zeros, or the end of the block.
   procedure Run_Symbols (R : Sample_Buffer; Counts : out Symbol_Counts; Value_Bits : out Unsigned_64) with SPARK_Mode => Off is
      Run : Natural := 0;
   begin
      Counts := [others => 0];
      Value_Bits := 0;
      for V of R loop
         if V = 0 then
            Run := Run + 1;
         else
            while Run >= 16 loop
               Counts (Sixteen_Zeros) := Counts (Sixteen_Zeros) + 1;
               Run := Run - 16;
            end loop;
            declare
               B : constant Natural := Bit_Length (Magnitude (V));
            begin
               Counts (Run * 64 + B) := Counts (Run * 64 + B) + 1;
               Value_Bits := Value_Bits + Unsigned_64 (B);
            end;
            Run := 0;
         end if;
      end loop;
      if Run > 0 then
         Counts (End_Of_Block) := Counts (End_Of_Block) + 1;
      end if;
   end Run_Symbols;

   --  Huffman code lengths: leaves sorted by count then symbol, two queues, a leaf before a node of equal weight.
   procedure Code_Lengths (Counts : Symbol_Counts; Lengths : out Symbol_Counts) with SPARK_Mode => Off is
      Leaf_Symbol, Leaf_Weight, Leaf_Parent : Symbol_Counts := [others => 0];
      Node_Weight, Node_Parent, Depth : Symbol_Counts := [others => 0];
      M, Next_Leaf, Next_Node : Natural := 0;
   begin
      Lengths := [others => 0];
      for S in Counts'Range loop
         if Counts (S) > 0 then
            declare
               J : Natural := M;
            begin
               while J > 0 and then Leaf_Weight (J - 1) > Counts (S) loop
                  Leaf_Weight (J) := Leaf_Weight (J - 1);
                  Leaf_Symbol (J) := Leaf_Symbol (J - 1);
                  J := J - 1;
               end loop;
               Leaf_Weight (J) := Counts (S);
               Leaf_Symbol (J) := S;
            end;
            M := M + 1;
         end if;
      end loop;
      if M = 1 then
         Lengths (Leaf_Symbol (0)) := 1;
      elsif M > 1 then
         for K in 0 .. M - 2 loop
            for Unused in 1 .. 2 loop
               if Next_Leaf < M and then (Next_Node = K or else Leaf_Weight (Next_Leaf) <= Node_Weight (Next_Node)) then
                  Leaf_Parent (Next_Leaf) := K;
                  Node_Weight (K) := Node_Weight (K) + Leaf_Weight (Next_Leaf);
                  Next_Leaf := Next_Leaf + 1;
               else
                  Node_Parent (Next_Node) := K;
                  Node_Weight (K) := Node_Weight (K) + Node_Weight (Next_Node);
                  Next_Node := Next_Node + 1;
               end if;
            end loop;
         end loop;
         for J in reverse 0 .. M - 3 loop
            Depth (J) := Depth (Node_Parent (J)) + 1;
         end loop;
         for I in 0 .. M - 1 loop
            Lengths (Leaf_Symbol (I)) := Depth (Leaf_Parent (I)) + 1;
         end loop;
      end if;
   end Code_Lengths;

   --  Canonical codes in symbol order, as in RFC 1951 section 3.2.2.
   procedure Canonical (Lengths : Symbol_Counts; Codes : out Code_Table) with SPARK_Mode => Off is
      Count : array (0 .. Longest_Code) of Unsigned_64 := [others => 0];
      Next : array (1 .. Longest_Code) of Unsigned_64;
      Code : Unsigned_64 := 0;
   begin
      for L of Lengths loop
         if L > 0 then
            Count (L) := Count (L) + 1;
         end if;
      end loop;
      for Bits in 1 .. Longest_Code loop
         Code := Shift_Left (Code + Count (Bits - 1), 1);
         Next (Bits) := Code;
      end loop;
      for S in Lengths'Range loop
         if Lengths (S) > 0 then
            Codes (S) := Next (Lengths (S));
            Next (Lengths (S)) := Next (Lengths (S)) + 1;
         else
            Codes (S) := 0;
         end if;
      end loop;
   end Canonical;

   function Run_Cost (R : Sample_Buffer) return Unsigned_64 with SPARK_Mode => Off is
      Counts, Lengths : Symbol_Counts;
      Value_Bits : Unsigned_64;
      Bits : Unsigned_64 := 11;
      Previous : Integer := -1;
   begin
      Run_Symbols (R, Counts, Value_Bits);
      Code_Lengths (Counts, Lengths);
      for S in Counts'Range loop
         if Counts (S) > 0 then
            Bits := Bits + Unsigned_64 (Gamma_Length (S - Previous)) + 5 + Unsigned_64 (Counts (S)) * Unsigned_64 (Lengths (S));
            Previous := S;
         end if;
      end loop;
      return Bits + Value_Bits;
   end Run_Cost;

   --  The number of symbols in 11 bits; each symbol as the gamma code of its step from the one before (the first
   --  from minus one) with its code length in 5 bits; then the codes. A value's code is followed by its sign and
   --  the bits below its leading one.
   procedure Put_Run (R : Sample_Buffer; Output : in out Byte_Array; Pos : in out Natural) with SPARK_Mode => Off is
      Counts, Lengths : Symbol_Counts;
      Codes : Code_Table;
      Value_Bits : Unsigned_64;
      M, Run : Natural := 0;
      Previous : Integer := -1;
   begin
      Run_Symbols (R, Counts, Value_Bits);
      Code_Lengths (Counts, Lengths);
      Canonical (Lengths, Codes);
      for C of Counts loop
         if C > 0 then
            M := M + 1;
         end if;
      end loop;
      Put (Output, Pos, Unsigned_64 (M), 11);
      for S in Counts'Range loop
         if Counts (S) > 0 then
            Put_Gamma (S - Previous, Output, Pos);
            Put (Output, Pos, Unsigned_64 (Lengths (S)), 5);
            Previous := S;
         end if;
      end loop;
      for V of R loop
         if V = 0 then
            Run := Run + 1;
         else
            while Run >= 16 loop
               Put (Output, Pos, Codes (Sixteen_Zeros), Lengths (Sixteen_Zeros));
               Run := Run - 16;
            end loop;
            declare
               B : constant Natural := Bit_Length (Magnitude (V));
               S : constant Natural := Run * 64 + B;
            begin
               Put (Output, Pos, Codes (S), Lengths (S));
               Put (Output, Pos, (if V < 0 then 1 else 0), 1);
               Put (Output, Pos, Magnitude (V), B - 1);
            end;
            Run := 0;
         end if;
      end loop;
      if Run > 0 then
         Put (Output, Pos, Codes (End_Of_Block), Lengths (End_Of_Block));
      end if;
   end Put_Run;

   procedure Encode (X : Sample_Array; Depth : Sample_Bits; Output : in out Byte_Array; Bytes : out Natural)
     with SPARK_Mode => Off
   is
      N : constant Natural := X'Length;
      Y, R : Sample_Buffer (0 .. N - 1);
      Pos : Natural := 0;
   begin
      if (for all V of X => V = X (X'First)) then
         Put (Output, Pos, 0, 1);
         Put (Output, Pos, Unsigned_64'Mod (X (X'First)), Depth);
      else
         declare
            Common : Unsigned_64 := 0;
            Shift : Natural := 0;
            Delay_Length : Natural;
            Best_Bits : Unsigned_64 := Unsigned_64'Last;
            Best_Predictor, Best_Coder, Best_K : Natural := 0;
         begin
            for V of X loop
               Common := Common or Unsigned_64'Mod (V);
            end loop;
            while (Shift_Right (Common, Shift) and 1) = 0 loop
               Shift := Shift + 1;
            end loop;
            for I in Y'Range loop
               Y (I) := X (X'First + I) / 2**Shift;
            end loop;
            Delay_Length := Find_Delay (Y);
            for Predictor in 0 .. Tier_Predictor loop
               if Predictor /= Delay_Predictor or else Delay_Length > 0 then
                  Residuals (Y, Predictor, Delay_Length, R);
                  declare
                     Header : constant Unsigned_64 := (if Predictor = Delay_Predictor then 22 else 10);
                     K : Natural;
                     Rice, Run : Unsigned_64;
                  begin
                     Rice_Cost (R, K, Rice);
                     Run := Run_Cost (R);
                     if Header + 6 + Rice < Best_Bits then
                        Best_Bits := Header + 6 + Rice;
                        Best_Predictor := Predictor;
                        Best_Coder := 0;
                        Best_K := K;
                     end if;
                     if Header + Run < Best_Bits then
                        Best_Bits := Header + Run;
                        Best_Predictor := Predictor;
                        Best_Coder := 1;
                     end if;
                  end;
               end if;
            end loop;
            Put (Output, Pos, 1, 1);
            Put (Output, Pos, Unsigned_64 (Shift), 5);
            Put (Output, Pos, Unsigned_64 (Best_Predictor), 3);
            if Best_Predictor = Delay_Predictor then
               Put (Output, Pos, Unsigned_64 (Delay_Length), 12);
            end if;
            Put (Output, Pos, Unsigned_64 (Best_Coder), 1);
            Residuals (Y, Best_Predictor, Delay_Length, R);
            if Best_Coder = 0 then
               Put_Rice (R, Best_K, Output, Pos);
            else
               Put_Run (R, Output, Pos);
            end if;
         end;
      end if;
      Put (Output, Pos, 0, (8 - Pos mod 8) mod 8);
      Bytes := Pos / 8;
   end Encode;

   ---------------------------------------------------------------------------------------------------------------
   --  Decoder

   subtype Residual is Long_Long_Integer range -(2**37) .. 2**37;
   type Residual_Buffer is array (Natural range <>) of Residual;

   procedure Get_Rice (Input : Byte_Array; Pos : in out Natural; Width : Width_Bits; R : in out Residual_Buffer; Status : out Status_Type)
     with Pre => Valid_Buffer (Input) and then Pos <= Input'Length * 8,
       Post => Pos <= Input'Length * 8
   is
      Total : constant Natural := Input'Length * 8;
      K, Bit, Low : Unsigned_64;
   begin
      Status := Truncated_Input;
      if Total - Pos < 6 then
         return;
      end if;
      Get (Input, Pos, K, 6);
      if K > Unsigned_64 (Width) + 5 then
         Status := Bad_Data;
         return;
      end if;
      for I in R'Range loop
         pragma Loop_Invariant (Pos <= Total and then K <= Unsigned_64 (Width) + 5);
         declare
            Q : Unsigned_64 := 0;
         begin
            loop
               pragma Loop_Invariant (Pos <= Total and then Q <= 2**40);
               if Pos = Total then
                  return;
               end if;
               Get (Input, Pos, Bit, 1);
               exit when Bit = 1;
               if Q = 2**40 then
                  Status := Bad_Data;
                  return;
               end if;
               Q := Q + 1;
            end loop;
            if Total - Pos < Natural (K) then
               return;
            end if;
            Get (Input, Pos, Low, Natural (K));
            if Q >= 2**(Width + 5 - Natural (K)) then
               Status := Bad_Data;
               return;
            end if;
            declare
               U : constant Unsigned_64 := Shift_Left (Q, Natural (K)) or (Low and (Shift_Left (1, Natural (K)) - 1));
            begin
               if U >= 2**(Width + 5) then
                  Status := Bad_Data;
                  return;
               end if;
               R (I) := (if U mod 2 = 0 then Long_Long_Integer (U / 2) else -Long_Long_Integer (U / 2) - 1);
            end;
         end;
      end loop;
      Status := Success;
   end Get_Rice;

   procedure Get_Run (Input : Byte_Array; Pos : in out Natural; Width : Width_Bits; R : in out Residual_Buffer; Status : out Status_Type)
     with Pre => Valid_Buffer (Input) and then Pos <= Input'Length * 8 and then R'First = 0 and then R'Length in Block_Length
       and then (for all V of R => V = 0),
       Post => Pos <= Input'Length * 8
   is
      use type Canonical_Decoding.Status_Type;
      Total : constant Natural := Input'Length * 8;
      Field : Unsigned_64;
      M : Natural;
      Entry_Symbol, Entry_Length : Symbol_Counts := [others => 0];
   begin
      Status := Truncated_Input;
      if Total - Pos < 11 then
         return;
      end if;
      Get (Input, Pos, Field, 11);
      if Field = 0 or else Field > Symbol_Count then
         Status := Bad_Data;
         return;
      end if;
      M := Natural (Field);
      for E in 0 .. M - 1 loop
         pragma Loop_Invariant (Pos <= Total and then (for all J in 0 .. E - 1 => Entry_Length (J) in 1 .. Longest_Code)
                                and then (if E > 0 then Entry_Symbol (E - 1) < Symbol_Count));
         declare
            Zeros : Natural := 0;
            Step : Unsigned_64;
         begin
            loop
               pragma Loop_Invariant (Pos <= Total and then Zeros <= 10);
               if Pos = Total then
                  return;
               end if;
               Get (Input, Pos, Field, 1);
               exit when Field = 1;
               if Zeros = 10 then
                  Status := Bad_Data;
                  return;
               end if;
               Zeros := Zeros + 1;
            end loop;
            if Total - Pos < Zeros + 5 then
               return;
            end if;
            Get (Input, Pos, Step, Zeros);
            Step := Shift_Left (1, Zeros) + Step;
            if Step > Unsigned_64 (Symbol_Count) - (if E = 0 then 0 else Unsigned_64 (Entry_Symbol (E - 1)) + 1) then
               Status := Bad_Data;
               return;
            end if;
            Entry_Symbol (E) := (if E = 0 then Natural (Step) - 1 else Entry_Symbol (E - 1) + Natural (Step));
            Get (Input, Pos, Field, 5);
            if Field = 0 then
               Status := Bad_Data;
               return;
            end if;
            Entry_Length (E) := Natural (Field);
         end;
      end loop;
      declare
         Codes : Canonical_Decoding.Table (Symbol_Count);
         Index : Positive := 1;
         I : Natural := 0;
         S : Long_Long_Integer;
         Decoded : Canonical_Decoding.Status_Type;
         N : constant Natural := R'Length;
      begin
         for E in 0 .. M - 1 loop
            pragma Loop_Invariant (Codes.Last_Length <= Longest_Code and then (for all L in 1 .. Canonical_Decoding.Max_Length => Codes.Counts (L) <= E));
            Codes.Counts (Entry_Length (E)) := Codes.Counts (Entry_Length (E)) + 1;
            Codes.Last_Length := Natural'Max (Codes.Last_Length, Entry_Length (E));
         end loop;
         for L in 1 .. Longest_Code loop
            for E in 0 .. M - 1 loop
               if Entry_Length (E) = L then
                  if Index > M then
                     Status := Bad_Data;
                     return;
                  end if;
                  Codes.Symbols (Index) := Long_Long_Integer (Entry_Symbol (E));
                  Index := Index + 1;
               end if;
            end loop;
         end loop;
         while I < N loop
            pragma Loop_Invariant (Pos <= Total and then I < N);
            Canonical_Decoding.Decode (Input, Pos, Codes, S, Decoded);
            if Decoded /= Canonical_Decoding.Success then
               Status := (if Decoded = Canonical_Decoding.Truncated_Input then Truncated_Input else Bad_Data);
               return;
            end if;
            if S = End_Of_Block then
               I := N;
            elsif S = Sixteen_Zeros then
               if N - I < 16 then
                  Status := Bad_Data;
                  return;
               end if;
               I := I + 16;
            elsif S not in 1 .. Symbol_Count - 1 or else S mod 64 = 0 or else S mod 64 > Long_Long_Integer (Width) + 4
              or else Long_Long_Integer (N - I) < S / 64 + 1
            then
               Status := Bad_Data;
               return;
            else
               declare
                  B : constant Positive := Positive (S mod 64);
                  Sign, Low : Unsigned_64;
               begin
                  I := I + Natural (S / 64);
                  if Total - Pos < B then
                     return;
                  end if;
                  Get (Input, Pos, Sign, 1);
                  Get (Input, Pos, Low, B - 1);
                  declare
                     V : constant Long_Long_Integer := Long_Long_Integer (Shift_Left (Unsigned_64'(1), B - 1) or Low);
                  begin
                     R (I) := (if Sign = 1 then -V else V);
                  end;
                  I := I + 1;
               end;
            end if;
         end loop;
      end;
      Status := Success;
   end Get_Run;

   procedure Decode (Input : Byte_Array; Depth : Sample_Bits; X : out Sample_Array; Used : out Natural; Status : out Status_Type) is
      N : constant Natural := X'Length;
      Total : constant Natural := Input'Length * 8;
      Pos : Natural := 0;
      Field : Unsigned_64;
      Shift, Predictor : Natural;
      Delay_Length : Natural := 0;
      Width : Width_Bits;
      R : Residual_Buffer (0 .. N - 1) := [others => 0];
      Y, Next : Sample_Buffer (0 .. N - 1) := [others => 0];
   begin
      X := [others => 0];
      Used := 0;
      Status := Truncated_Input;
      if Total < 1 then
         return;
      end if;
      Get (Input, Pos, Field, 1);
      if Field = 0 then
         if Total - Pos < Depth then
            return;
         end if;
         Get (Input, Pos, Field, Depth);
         X := [others => Sign_Extend (Field and (2**Depth - 1), Depth)];
         Used := (Pos + 7) / 8;
         Status := Success;
         return;
      end if;
      if Total - Pos < 8 then
         return;
      end if;
      Get (Input, Pos, Field, 5);
      Shift := Natural (Field);
      Get (Input, Pos, Field, 3);
      Predictor := Natural (Field);
      if Shift >= Depth or else Predictor > Tier_Predictor then
         Status := Bad_Data;
         return;
      end if;
      Width := Depth - Shift;
      if Predictor = Delay_Predictor then
         if Total - Pos < 12 then
            return;
         end if;
         Get (Input, Pos, Field, 12);
         Delay_Length := Natural (Field);
         if Delay_Length = 0 or else Delay_Length >= N then
            Status := Bad_Data;
            return;
         end if;
      end if;
      if Total - Pos < 1 then
         return;
      end if;
      Get (Input, Pos, Field, 1);
      if Field = 0 then
         Get_Rice (Input, Pos, Width, R, Status);
      else
         Get_Run (Input, Pos, Width, R, Status);
      end if;
      if Status /= Success then
         return;
      end if;
      Status := Bad_Data;

      --  Rebuild the samples, refusing any that leave the coded width:
      if Predictor = Tier_Predictor then
         declare
            Lengths : array (0 .. 16) of Natural := [others => 0];
            T : Natural := 0;
            Ptr : Natural;
         begin
            Lengths (0) := N;
            while Lengths (T) > 2 loop
               pragma Loop_Invariant (T < 16 and then Lengths (T) <= N);
               if T = 15 then
                  return;
               end if;
               Lengths (T + 1) := Lengths (T) / 2 + Lengths (T) mod 2;
               T := T + 1;
            end loop;
            for J in 0 .. Lengths (T) - 1 loop
               if not In_Range (R (J), Width) then
                  return;
               end if;
               Y (J) := R (J);
            end loop;
            Ptr := Lengths (T);
            for Level in reverse 0 .. T - 1 loop
               declare
                  L : constant Natural := Lengths (Level);
                  G : constant Natural := L / 2;
               begin
                  if L > N or else G = 0 or else Ptr > N - G or else Lengths (Level + 1) /= G + L mod 2 then
                     return;
                  end if;
                  for J in 0 .. G - 1 loop
                     declare
                        A : constant Sample := Y (J);
                        F : constant Sample := (if J < G - 1 then Y (J + 1) else Y (J));
                        V : constant Long_Long_Integer := R (Ptr + J) + (A + F) / 2;
                     begin
                        if not In_Range (V, Width) then
                           return;
                        end if;
                        Next (2 * J) := A;
                        Next (2 * J + 1) := V;
                     end;
                  end loop;
                  if L mod 2 = 1 then
                     Next (L - 1) := Y (G);
                  end if;
                  Ptr := Ptr + G;
                  Y (0 .. L - 1) := Next (0 .. L - 1);
               end;
            end loop;
         end;
      else
         for I in 0 .. N - 1 loop
            declare
               V : constant Long_Long_Integer :=
                 R (I) + (if Predictor = Delay_Predictor then (if I = 0 then 0 elsif I < Delay_Length then Y (I - 1) else Y (I - Delay_Length))
                          else Fixed_Prediction (Y, I, Natural'Min (Predictor, I)));
            begin
               if not In_Range (V, Width) then
                  return;
               end if;
               Y (I) := V;
            end;
         end loop;
      end if;
      for I in 0 .. N - 1 loop
         if not In_Range (Y (I), Width) then
            return;
         end if;
         X (X'First + I) := Y (I) * Half (Shift + 1);
      end loop;
      Used := (Pos + 7) / 8;
      Status := Success;
   end Decode;

end Block_Codec;
