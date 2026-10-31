with Interfaces; use Interfaces;

package body Predictors is

   function Predict (X : Value_Array; N : Natural; Order : Fixed_Order) return Long_Long_Integer is
      function S (K : Positive) return Long_Long_Integer is (if N - X'First >= K then X (N - K) else 0);
   begin
      return (case Order is
                when 0 => 0,
                when 1 => S (1),
                when 2 => 2 * S (1) - S (2),
                when 3 => 3 * S (1) - 3 * S (2) + S (3),
                when 4 => 4 * S (1) - 6 * S (2) + 4 * S (3) - S (4));
   end Predict;

   function Best_Order (X : Value_Array; First, Last : Natural) return Fixed_Order is
      Best : Fixed_Order := 0;
      Best_Sum : Long_Long_Integer := Long_Long_Integer'Last;
   begin
      for Order in Fixed_Order loop
         declare
            Sum : Long_Long_Integer := 0;
         begin
            for N in First .. Last loop
               Sum := Sum + abs (X (N) - Predict (X, N, Order));
            end loop;
            if Sum < Best_Sum then
               Best := Order;
               Best_Sum := Sum;
            end if;
         end;
      end loop;
      return Best;
   end Best_Order;

   type Access_Array is array (Natural range <>) of Value_Array_Access;

   --  The next tier holds the first sample of each whole group, then the samples left over.
   function Next_Length (Len : Natural; Group : Positive) return Natural is (Len / Group + Len mod Group);

   function Tier_Count (N : Natural; Group : Positive) return Natural is
      Len : Natural := N;
      Count : Natural := 0;
   begin
      while Len > Group loop
         Len := Next_Length (Len, Group);
         Count := Count + 1;
      end loop;
      return Count;
   end Tier_Count;

   procedure Split (Sig : Value_Array; Group : Positive; Mode : Tier_Mode; Diff : out Value_Array; Next : out Value_Array) is
      Groups : constant Natural := Sig'Length / Group;
   begin
      for J in 0 .. Groups - 1 loop
         declare
            Base : constant Natural := Sig'First + J * Group;
            Following : constant Long_Long_Integer := (if J < Groups - 1 then Sig (Base + Group) else Sig (Base));
         begin
            Next (Next'First + J) := Sig (Base);
            for I in 1 .. Group - 1 loop
               Diff (Diff'First + J * (Group - 1) + I - 1) :=
                 Sig (Base + I) - (case Mode is
                                     when From_Start => Sig (Base),
                                     when Successive => Sig (Base + I - 1),
                                     when Mean_Of_Anchors => (Sig (Base) + Following) / 2);
            end loop;
         end;
      end loop;
      for K in 0 .. Sig'Length mod Group - 1 loop
         Next (Next'First + Groups + K) := Sig (Sig'First + Groups * Group + K);
      end loop;
   end Split;

   procedure Join (Next : Value_Array; Diff : Value_Array; Group : Positive; Mode : Tier_Mode; Sig : out Value_Array) is
      Groups : constant Natural := Sig'Length / Group;
   begin
      for J in 0 .. Groups - 1 loop
         declare
            Base : constant Natural := Sig'First + J * Group;
            Anchor : constant Long_Long_Integer := Next (Next'First + J);
            Following : constant Long_Long_Integer := (if J < Groups - 1 then Next (Next'First + J + 1) else Anchor);
         begin
            Sig (Base) := Anchor;
            for I in 1 .. Group - 1 loop
               Sig (Base + I) := Diff (Diff'First + J * (Group - 1) + I - 1)
                 + (case Mode is
                      when From_Start => Anchor,
                      when Successive => Sig (Base + I - 1),
                      when Mean_Of_Anchors => (Anchor + Following) / 2);
            end loop;
         end;
      end loop;
      for K in 0 .. Sig'Length mod Group - 1 loop
         Sig (Sig'First + Groups * Group + K) := Next (Next'First + Groups + K);
      end loop;
   end Join;

   procedure Encode_Tiers (X : Value_Array; Group : Positive; Mode : Tier_Mode; Buffer : in out Byte_Array; Pos : in out Natural; Finest_Bits : out Natural) is
      Count : constant Natural := Tier_Count (X'Length, Group);
      Sigs : Access_Array (0 .. Count);
      Diffs : Access_Array (0 .. Count - 1);
   begin
      Sigs (0) := new Value_Array'(X);
      for T in 0 .. Count - 1 loop
         declare
            Len : constant Natural := Sigs (T)'Length;
         begin
            Diffs (T) := new Value_Array (0 .. Len / Group * (Group - 1) - 1);
            Sigs (T + 1) := new Value_Array (0 .. Next_Length (Len, Group) - 1);
            Split (Sigs (T).all, Group, Mode, Diffs (T).all, Sigs (T + 1).all);
         end;
      end loop;
      for V of Sigs (Count).all loop
         Put_Gamma (Buffer, Pos, Zigzag (V) + 1);
      end loop;
      Finest_Bits := 0;
      for T in reverse 0 .. Count - 1 loop
         declare
            Start : constant Natural := Pos;
         begin
            Huffman_Codes.Encode (Diffs (T).all, Buffer, Pos);
            if T = 0 then
               Finest_Bits := Pos - Start;
            end if;
         end;
      end loop;
      for S of Sigs loop
         Free (S);
      end loop;
      for D of Diffs loop
         Free (D);
      end loop;
   end Encode_Tiers;

   procedure Decode_Tiers (Buffer : Byte_Array; Pos : in out Natural; Group : Positive; Mode : Tier_Mode; X : out Value_Array) is
      Count : constant Natural := Tier_Count (X'Length, Group);
      Lens : array (0 .. Count) of Natural;
      Next : Value_Array_Access;
      N : Unsigned_64;
   begin
      Lens (0) := X'Length;
      for T in 1 .. Count loop
         Lens (T) := Next_Length (Lens (T - 1), Group);
      end loop;
      Next := new Value_Array (0 .. Lens (Count) - 1);
      for V of Next.all loop
         Get_Gamma (Buffer, Pos, N);
         V := Unzigzag (N - 1);
      end loop;
      for T in reverse 0 .. Count - 1 loop
         declare
            Diff : Value_Array_Access := new Value_Array (0 .. Lens (T) / Group * (Group - 1) - 1);
            Sig : constant Value_Array_Access := new Value_Array (0 .. Lens (T) - 1);
         begin
            Huffman_Codes.Decode (Buffer, Pos, Diff.all);
            Join (Next.all, Diff.all, Group, Mode, Sig.all);
            Free (Diff);
            Free (Next);
            Next := Sig;
         end;
      end loop;
      X := Next.all;
      Free (Next);
   end Decode_Tiers;

end Predictors;
