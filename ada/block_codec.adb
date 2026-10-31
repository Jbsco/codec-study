with Interfaces; use Interfaces;
with Canonical_Decoding;

package body Block_Codec with SPARK_Mode is

   Delay_Predictor : constant := 5;
   Tier_Predictor : constant := 6;
   Lpc_Predictor : constant := 7;
   Max_Order : constant := 32;
   Ramp_Order : constant := 2;
   Symbol_Count : constant := 1024;
   End_Of_Block : constant := 0;
   Sixteen_Zeros : constant := 15 * 64;
   Match_Length : constant := 32;
   Longest_Code : constant := 31;

   subtype Width_Bits is Positive range 1 .. 33;
   subtype Sample is Long_Long_Integer range -(2**36) .. 2**36;
   type Sample_Buffer is array (Natural range <>) of Sample;

   type Symbol_Counts is array (0 .. Symbol_Count - 1) of Natural;
   type Code_Table is array (0 .. Symbol_Count - 1) of Unsigned_64;

   subtype Coefficient is Long_Long_Integer range -(2**15) .. 2**15;
   type Coefficient_Array is array (1 .. Max_Order) of Coefficient;

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
     with Pre => U < 2**33;

   --  The order-K polynomial prediction of Y (I) from the K samples before it.
   function Fixed_Prediction (Y : Sample_Buffer; I, K : Natural) return Long_Long_Integer is
     (case K is
        when 0 => 0,
        when 1 => Y (I - 1),
        when 2 => 2 * Y (I - 1) - Y (I - 2),
        when 3 => 3 * Y (I - 1) - 3 * Y (I - 2) + Y (I - 3),
        when others => 4 * Y (I - 1) - 6 * Y (I - 2) + 4 * Y (I - 3) - Y (I - 4))
     with Pre => K <= 4 and then K <= I and then I in Y'Range and then Y'First = 0;

   --  V divided by 2**S, rounded down.
   function Floor_Shift (V : Long_Long_Integer; S : Natural) return Long_Long_Integer is
     (if V >= 0 then V / Half (S + 1) else -((-(V + 1)) / Half (S + 1)) - 1)
     with Pre => S <= 31 and then V in -(2**60) .. 2**60,
       Post => Floor_Shift'Result in -(2**60) .. 2**60;

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

   --  The smallest distance P, at most the length of History, at which the first 32 samples of X repeat the
   --  samples P before them, counting back into History, or zero.
   function Find_Back (X, History : Sample_Array) return Natural with SPARK_Mode => Off is
      function Before (K : Integer) return Long_Long_Integer is
        (if K >= 0 then X (X'First + K) else History (History'Last + 1 + K));
   begin
      if X'Length >= Match_Length then
         for P in 1 .. History'Length loop
            if (for all J in 0 .. Match_Length - 1 => Before (J - P) = X (X'First + J)) then
               return P;
            end if;
         end loop;
      end if;
      return 0;
   end Find_Back;

   --  Residuals from the sample Back before each one, the samples of History scaled down by the shift.
   procedure Back_Residuals (Y : Sample_Buffer; History : Sample_Array; Back, Shift : Natural; R : out Sample_Buffer)
     with SPARK_Mode => Off
   is
   begin
      for I in Y'Range loop
         R (I) := Y (I) - (if I >= Back then Y (I - Back) else Floor_Shift (History (History'Last + 1 + I - Back), Shift));
      end loop;
   end Back_Residuals;

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

   --  The Rice parameter of least cost, the smallest of equals, walked from the bit length of the mean code value;
   --  the cost is convex in the parameter.
   procedure Rice_Cost (R : Sample_Buffer; K : out Natural; Bits : out Unsigned_64) with SPARK_Mode => Off is
      function Cost (P : Natural) return Unsigned_64 is
         C : Unsigned_64 := Unsigned_64 (R'Length) * Unsigned_64 (P + 1);
      begin
         for V of R loop
            C := C + Shift_Right (Zigzag (V), P);
         end loop;
         return C;
      end Cost;
      Sum : Unsigned_64 := 0;
      Moved : Boolean := False;
   begin
      for V of R loop
         Sum := Sum + Zigzag (V);
      end loop;
      K := Natural'Max (Bit_Length (Sum / Unsigned_64 (R'Length)), 1) - 1;
      Bits := Cost (K);
      while K > 0 loop
         declare
            C : constant Unsigned_64 := Cost (K - 1);
         begin
            exit when C > Bits;
            K := K - 1;
            Bits := C;
            Moved := True;
         end;
      end loop;
      while not Moved and then K < 62 loop
         declare
            C : constant Unsigned_64 := Cost (K + 1);
         begin
            exit when C >= Bits;
            K := K + 1;
            Bits := C;
         end;
      end loop;
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

   type Real_Array is array (Natural range <>) of Long_Float;
   type Coefficient_Sets is array (1 .. Max_Order, 1 .. Max_Order) of Long_Float;

   --  Predictor coefficients for each order up to Max_Order, from the Levinson-Durbin recursion on the
   --  autocorrelation of the block under a window whose first and last quarters rise as a smoothstep.
   procedure Lpc_Analysis (Y : Sample_Buffer; Sets : out Coefficient_Sets; Orders : out Natural) with SPARK_Mode => Off is
      N : constant Natural := Y'Length;
      M : constant Natural := Natural'Max (1, N / 4);
      Top : constant Natural := Natural'Min (Max_Order, N - 1);
      Tapered : Real_Array (0 .. N - 1);
      Ac, A, Next : Real_Array (0 .. Max_Order) := [others => 0.0];
      Err : Long_Float;
   begin
      Sets := [others => [others => 0.0]];
      Orders := 0;
      for I in 0 .. N - 1 loop
         declare
            T : constant Long_Float := Long_Float'Min (1.0, Long_Float (Natural'Min (I + 1, N - I)) / Long_Float (M + 1));
         begin
            Tapered (I) := Long_Float (Y (I)) * (T * T * (3.0 - 2.0 * T));
         end;
      end loop;
      for K in 0 .. Top loop
         for I in 0 .. N - 1 - K loop
            Ac (K) := Ac (K) + Tapered (I) * Tapered (I + K);
         end loop;
      end loop;
      if not (Ac (0) > 0.0) then
         return;
      end if;
      A (0) := 1.0;
      Err := Ac (0);
      for P in 1 .. Top loop
         declare
            Acc : Long_Float := Ac (P);
            K : Long_Float;
         begin
            for J in 1 .. P - 1 loop
               Acc := Acc + A (J) * Ac (P - J);
            end loop;
            K := -Acc / Err;
            for J in 1 .. P - 1 loop
               Next (J) := A (J) + K * A (P - J);
            end loop;
            A (1 .. P - 1) := Next (1 .. P - 1);
            A (P) := K;
            Err := Err * (1.0 - K * K);
            for J in 1 .. P loop
               Sets (P, J) := -A (J);
            end loop;
            Orders := P;
            exit when not (Err > 0.0);
         end;
      end loop;
   end Lpc_Analysis;

   --  The coefficients of one order as Precision-bit integers over 2**Shift, each rounded with the error of the
   --  ones before it carried forward.
   procedure Quantize (Sets : Coefficient_Sets; Order, Precision : Positive; Q : out Coefficient_Array; Shift : out Natural;
                       Ok : out Boolean) with SPARK_Mode => Off
   is
      Peak, Carry : Long_Float := 0.0;
      Limit : constant Long_Long_Integer := 2**(Precision - 1);
   begin
      Q := [others => 0];
      Shift := 0;
      Ok := False;
      for J in 1 .. Order loop
         if not (abs Sets (Order, J) < 1.0E300) then
            return;
         end if;
         Peak := Long_Float'Max (Peak, abs Sets (Order, J));
      end loop;
      if not (Peak > 0.0) or else Precision - 1 - Long_Float'Exponent (Peak) < 0 then
         return;
      end if;
      Shift := Natural'Min (Precision - 1 - Long_Float'Exponent (Peak), 31);
      for J in 1 .. Order loop
         Carry := Carry + Sets (Order, J) * 2.0 ** Shift;
         declare
            V : constant Long_Long_Integer :=
              Long_Long_Integer'Max (-Limit, Long_Long_Integer'Min (Limit - 1, Long_Long_Integer (Long_Float'Floor (Carry + 0.5))));
         begin
            Q (J) := V;
            Carry := Carry - Long_Float (V);
         end;
      end loop;
      Ok := True;
   end Quantize;

   --  The ramp of the first Order samples into Warm, and the prediction residuals of the rest into R. Fits is
   --  false when a residual needs more than Width + 4 bits.
   procedure Lpc_Residuals (Y : Sample_Buffer; Q : Coefficient_Array; Order, Shift : Natural; Width : Width_Bits;
                            Warm, R : out Sample_Buffer; Fits : out Boolean) with SPARK_Mode => Off
   is
      Limit : constant Long_Long_Integer := Half (Width + 4);
   begin
      Fits := True;
      for I in 0 .. Order - 1 loop
         Warm (Warm'First + I) := Y (I) - Fixed_Prediction (Y, I, Natural'Min (Ramp_Order, I));
      end loop;
      for I in Order .. Y'Last loop
         declare
            Sum : Long_Long_Integer := 0;
            V : Long_Long_Integer;
         begin
            for J in 1 .. Order loop
               Sum := Sum + Q (J) * Y (I - J);
            end loop;
            V := Y (I) - Floor_Shift (Sum, Shift);
            if V <= -Limit or else V >= Limit then
               Fits := False;
               V := 0;
            end if;
            R (R'First + I - Order) := V;
         end;
      end loop;
   end Lpc_Residuals;

   type Lpc_Choice is record
      Order, Precision, Shift, K, Warm_K : Natural := 0;
      Rice : Boolean := True;
      Q : Coefficient_Array := [others => 0];
   end record;

   --  The shortest LPC coding: the order with the least Rice cost at 15-bit precision, then the precision and the
   --  residual code with the least cost at that order.
   procedure Best_Lpc (Y : Sample_Buffer; Width : Width_Bits; Bits : out Unsigned_64; Choice : out Lpc_Choice)
     with SPARK_Mode => Off
   is
      N : constant Natural := Y'Length;
      Sets : Coefficient_Sets;
      Orders, Best_Order : Natural := 0;
      Warm : Sample_Buffer (0 .. Max_Order - 1);
      R : Sample_Buffer (0 .. N - 1);
      Least : Unsigned_64 := Unsigned_64'Last;
      Q : Coefficient_Array;
      Shift, Kw, Kr : Natural;
      Ok, Fits : Boolean;
      Cw, Cr : Unsigned_64;
   begin
      Bits := Unsigned_64'Last;
      Choice := (others => <>);
      Lpc_Analysis (Y, Sets, Orders);
      for Order in 1 .. Orders loop
         Quantize (Sets, Order, 15, Q, Shift, Ok);
         if Ok then
            Lpc_Residuals (Y, Q, Order, Shift, Width, Warm (0 .. Order - 1), R (0 .. N - Order - 1), Fits);
            if Fits then
               Rice_Cost (Warm (0 .. Order - 1), Kw, Cw);
               Rice_Cost (R (0 .. N - Order - 1), Kr, Cr);
               if 24 + Unsigned_64 (15 * Order) + 6 + Cw + 6 + Cr < Least then
                  Least := 24 + Unsigned_64 (15 * Order) + 6 + Cw + 6 + Cr;
                  Best_Order := Order;
               end if;
            end if;
         end if;
      end loop;
      if Best_Order = 0 then
         return;
      end if;
      for Precision in 5 .. 15 loop
         Quantize (Sets, Best_Order, Precision, Q, Shift, Ok);
         if Ok then
            Lpc_Residuals (Y, Q, Best_Order, Shift, Width, Warm (0 .. Best_Order - 1), R (0 .. N - Best_Order - 1), Fits);
            if Fits then
               Rice_Cost (Warm (0 .. Best_Order - 1), Kw, Cw);
               Rice_Cost (R (0 .. N - Best_Order - 1), Kr, Cr);
               declare
                  Head : constant Unsigned_64 := 24 + Unsigned_64 (Precision * Best_Order) + 6 + Cw;
                  Run : constant Unsigned_64 := Run_Cost (R (0 .. N - Best_Order - 1));
               begin
                  if Head + 6 + Cr < Bits then
                     Bits := Head + 6 + Cr;
                     Choice := (Best_Order, Precision, Shift, Kr, Kw, True, Q);
                  end if;
                  if Head + Run < Bits then
                     Bits := Head + Run;
                     Choice := (Best_Order, Precision, Shift, Kr, Kw, False, Q);
                  end if;
               end;
            end if;
         end if;
      end loop;
   end Best_Lpc;

   procedure Encode (X, History : Sample_Array; Depth : Sample_Bits; Output : in out Byte_Array; Bytes : out Natural)
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
            Back : constant Natural := Find_Back (X, History);
            From_History : Boolean := False;
            Best_Bits, Lpc_Bits : Unsigned_64 := Unsigned_64'Last;
            Best_Predictor, Best_Coder, Best_K : Natural := 0;
            Lpc : Lpc_Choice;
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
                     Header : constant Unsigned_64 := (if Predictor = Delay_Predictor then 23 else 10);
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
            if Back > 0 then
               Back_Residuals (Y, History, Back, Shift, R);
               declare
                  K : Natural;
                  Rice, Run : Unsigned_64;
               begin
                  Rice_Cost (R, K, Rice);
                  Run := Run_Cost (R);
                  if 26 + 6 + Rice < Best_Bits then
                     Best_Bits := 26 + 6 + Rice;
                     Best_Predictor := Delay_Predictor;
                     Best_Coder := 0;
                     Best_K := K;
                     From_History := True;
                  end if;
                  if 26 + Run < Best_Bits then
                     Best_Bits := 26 + Run;
                     Best_Predictor := Delay_Predictor;
                     Best_Coder := 1;
                     From_History := True;
                  end if;
               end;
            end if;
            Best_Lpc (Y, Depth - Shift, Lpc_Bits, Lpc);
            Put (Output, Pos, 1, 1);
            Put (Output, Pos, Unsigned_64 (Shift), 5);
            if Lpc_Bits < Best_Bits then
               Put (Output, Pos, Lpc_Predictor, 3);
               Put (Output, Pos, Unsigned_64 (Lpc.Order - 1), 5);
               Put (Output, Pos, Unsigned_64 (Lpc.Precision - 1), 4);
               Put (Output, Pos, Unsigned_64 (Lpc.Shift), 5);
               for J in 1 .. Lpc.Order loop
                  Put (Output, Pos, Unsigned_64'Mod (Lpc.Q (J)), Lpc.Precision);
               end loop;
               declare
                  Warm : Sample_Buffer (0 .. Lpc.Order - 1);
                  Fits : Boolean;
               begin
                  Lpc_Residuals (Y, Lpc.Q, Lpc.Order, Lpc.Shift, Depth - Shift, Warm, R (0 .. N - Lpc.Order - 1), Fits);
                  Put_Rice (Warm, Lpc.Warm_K, Output, Pos);
               end;
               Put (Output, Pos, (if Lpc.Rice then 0 else 1), 1);
               if Lpc.Rice then
                  Put_Rice (R (0 .. N - Lpc.Order - 1), Lpc.K, Output, Pos);
               else
                  Put_Run (R (0 .. N - Lpc.Order - 1), Output, Pos);
               end if;
            else
               Put (Output, Pos, Unsigned_64 (Best_Predictor), 3);
               if Best_Predictor = Delay_Predictor then
                  Put (Output, Pos, Boolean'Pos (From_History), 1);
                  if From_History then
                     Put (Output, Pos, Unsigned_64 (Back), 15);
                  else
                     Put (Output, Pos, Unsigned_64 (Delay_Length), 12);
                  end if;
               end if;
               Put (Output, Pos, Unsigned_64 (Best_Coder), 1);
               if From_History then
                  Back_Residuals (Y, History, Back, Shift, R);
               else
                  Residuals (Y, Best_Predictor, Delay_Length, R);
               end if;
               if Best_Coder = 0 then
                  Put_Rice (R, Best_K, Output, Pos);
               else
                  Put_Run (R, Output, Pos);
               end if;
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

   --  An LPC block after its predictor field: the order, precision and shift of the coefficients, the
   --  coefficients, the ramp of the first samples in Rice codes, then the residuals of the rest.
   procedure Decode_Lpc (Input : Byte_Array; Pos : in out Natural; Width : Width_Bits; Y : in out Sample_Buffer;
                         Status : out Status_Type)
     with Pre => Valid_Buffer (Input) and then Pos <= Input'Length * 8 and then Y'First = 0 and then Y'Length in Block_Length,
       Post => Pos <= Input'Length * 8
   is
      Total : constant Natural := Input'Length * 8;
      N : constant Natural := Y'Length;
      Field : Unsigned_64;
      Order, Precision, Shift : Natural;
      Q : Coefficient_Array := [others => 0];
   begin
      Status := Truncated_Input;
      if Total - Pos < 14 then
         return;
      end if;
      Get (Input, Pos, Field, 5);
      Order := Natural (Field) + 1;
      Get (Input, Pos, Field, 4);
      Precision := Natural (Field) + 1;
      Get (Input, Pos, Field, 5);
      Shift := Natural (Field);
      if Order >= N then
         Status := Bad_Data;
         return;
      end if;
      for J in 1 .. Order loop
         pragma Loop_Invariant (Pos <= Total);
         if Total - Pos < Precision then
            return;
         end if;
         Get (Input, Pos, Field, Precision);
         declare
            V : constant Long_Long_Integer :=
              Long_Long_Integer (Field and 16#FFFF#) - (if Field >= Unsigned_64 (Half (Precision)) then 2 * Half (Precision) else 0);
         begin
            if V not in Coefficient then
               Status := Bad_Data;
               return;
            end if;
            Q (J) := V;
         end;
      end loop;
      declare
         Ramp_Last : constant Natural := Order - 1;
         Warm : Residual_Buffer (0 .. Ramp_Last) := [others => 0];
      begin
         Get_Rice (Input, Pos, Width, Warm, Status);
         if Status /= Success then
            return;
         end if;
         for I in 0 .. Ramp_Last loop
            declare
               V : constant Long_Long_Integer := Warm (I) + Fixed_Prediction (Y, I, Natural'Min (Ramp_Order, I));
            begin
               if not In_Range (V, Width) then
                  Status := Bad_Data;
                  return;
               end if;
               Y (I) := V;
            end;
         end loop;
      end;
      Status := Truncated_Input;
      if Total - Pos < 1 then
         return;
      end if;
      Get (Input, Pos, Field, 1);
      declare
         Count : constant Natural := N - Order;
         R : Residual_Buffer (0 .. Count - 1) := [others => 0];
      begin
         if Field = 0 then
            Get_Rice (Input, Pos, Width, R, Status);
         else
            Get_Run (Input, Pos, Width, R, Status);
         end if;
         if Status /= Success then
            return;
         end if;
         for I in Order .. N - 1 loop
            declare
               Sum : Long_Long_Integer := 0;
            begin
               for J in 1 .. Order loop
                  pragma Loop_Invariant (Sum in -(Long_Long_Integer (J - 1) * 2**51) .. Long_Long_Integer (J - 1) * 2**51);
                  Sum := Sum + Q (J) * Y (I - J);
               end loop;
               declare
                  V : constant Long_Long_Integer := R (I - Order) + Floor_Shift (Sum, Shift);
               begin
                  if not In_Range (V, Width) then
                     Status := Bad_Data;
                     return;
                  end if;
                  Y (I) := V;
               end;
            end;
         end loop;
      end;
   end Decode_Lpc;

   procedure Decode (Input : Byte_Array; History : Sample_Array; Depth : Sample_Bits; X : out Sample_Array; Used : out Natural;
                     Status : out Status_Type) is
      N : constant Natural := X'Length;
      Total : constant Natural := Input'Length * 8;
      Pos : Natural := 0;
      Field : Unsigned_64;
      Shift, Predictor : Natural;
      Delay_Length : Natural := 0;
      From_History : Boolean := False;
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
      if Shift >= Depth then
         Status := Bad_Data;
         return;
      end if;
      Width := Depth - Shift;
      if Predictor = Delay_Predictor then
         if Total - Pos < 1 then
            return;
         end if;
         Get (Input, Pos, Field, 1);
         From_History := Field = 1;
         if Total - Pos < (if From_History then 15 else 12) then
            return;
         end if;
         Get (Input, Pos, Field, (if From_History then 15 else 12));
         Delay_Length := Natural (Field);
         if Delay_Length = 0 or else (if From_History then Delay_Length > History'Length else Delay_Length >= N) then
            Status := Bad_Data;
            return;
         end if;
      end if;
      if Predictor = Lpc_Predictor then
         Decode_Lpc (Input, Pos, Width, Y, Status);
      else
         if Total - Pos < 1 then
            return;
         end if;
         Get (Input, Pos, Field, 1);
         if Field = 0 then
            Get_Rice (Input, Pos, Width, R, Status);
         else
            Get_Run (Input, Pos, Width, R, Status);
         end if;
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
      elsif Predictor /= Lpc_Predictor then
         for I in 0 .. N - 1 loop
            declare
               V : constant Long_Long_Integer :=
                 R (I) + (if Predictor /= Delay_Predictor then Fixed_Prediction (Y, I, Natural'Min (Predictor, I))
                          elsif I >= Delay_Length then Y (I - Delay_Length)
                          elsif From_History then Floor_Shift (History (History'Last - (Delay_Length - 1 - I)), Shift)
                          elsif I = 0 then 0
                          else Y (I - 1));
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
