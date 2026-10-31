with Interfaces; use Interfaces;
with Canonical_Decoding;

package body Residual_Coders is

   Parameter_Bits : constant := 6;
   Category_Bits : constant := 6;
   Length_Bits : constant := 5;

   function Magnitude (V : Long_Long_Integer) return Unsigned_64 is
     (if V < 0 then Unsigned_64 (-(V + 1)) + 1 else Unsigned_64 (V));

   function Bit_Length (V : Long_Long_Integer) return Natural is
      U : Unsigned_64 := Magnitude (V);
      Bits : Natural := 0;
   begin
      while U > 0 loop
         Bits := Bits + 1;
         U := Shift_Right (U, 1);
      end loop;
      return Bits;
   end Bit_Length;

   --  The cost of a Rice parameter falls and then rises, so the search stops at the first rise.
   procedure Put_Rice (Data : Value_Array; Buffer : in out Byte_Array; Pos : in out Natural) is
      Best : Natural := 0;
      Best_Bits : Unsigned_64 := Unsigned_64'Last;
   begin
      for K in 0 .. 2**Parameter_Bits - 2 loop
         declare
            Bits : Unsigned_64 := Unsigned_64 (Data'Length) * Unsigned_64 (K + 1);
         begin
            for V of Data loop
               Bits := Bits + Shift_Right (Zigzag (V), K);
            end loop;
            exit when Bits >= Best_Bits;
            Best := K;
            Best_Bits := Bits;
         end;
      end loop;
      Put (Buffer, Pos, Unsigned_64 (Best), Parameter_Bits);
      Side_Bits := Side_Bits + Parameter_Bits;
      for V of Data loop
         declare
            U : constant Unsigned_64 := Zigzag (V);
            Quotient : Unsigned_64 := Shift_Right (U, Best);
         begin
            while Quotient > 0 loop
               declare
                  Step : constant Natural := Natural (Unsigned_64'Min (Quotient, 64));
               begin
                  Put (Buffer, Pos, 0, Step);
                  Quotient := Quotient - Unsigned_64 (Step);
               end;
            end loop;
            Put (Buffer, Pos, 1, 1);
            Put (Buffer, Pos, U and (Shift_Left (1, Best) - 1), Best);
         end;
      end loop;
   end Put_Rice;

   procedure Get_Rice (Buffer : Byte_Array; Pos : in out Natural; Data : out Value_Array) is
      K, Bit, Low : Unsigned_64;
   begin
      Get (Buffer, Pos, K, Parameter_Bits);
      for V of Data loop
         declare
            Quotient : Unsigned_64 := 0;
         begin
            loop
               Get (Buffer, Pos, Bit, 1);
               exit when Bit = 1;
               Quotient := Quotient + 1;
            end loop;
            Get (Buffer, Pos, Low, Natural (K));
            V := Unzigzag (Shift_Left (Quotient, Natural (K)) or Low);
         end;
      end loop;
   end Get_Rice;

   --  The largest bit length used, L, in 6 bits and the code lengths of bit lengths 0 to L in 5 bits each,
   --  then per residual the code of its bit length B and, when B is above zero, a sign bit and the B - 1
   --  bits below the leading one.
   procedure Put_Bit_Length (Data : Value_Array; Buffer : in out Byte_Array; Pos : in out Natural) is
      Counts : Count_Array (0 .. 2**Category_Bits - 1) := [others => 0];
      Last, Used : Natural := 0;
   begin
      for V of Data loop
         Counts (Bit_Length (V)) := Counts (Bit_Length (V)) + 1;
      end loop;
      for S in Counts'Range loop
         if Counts (S) > 0 then
            Used := Used + 1;
            Last := S;
         end if;
      end loop;
      declare
         Lengths : Length_Array (0 .. Last) := [others => 0];
         Codes : Code_Array (0 .. Last);
      begin
         if Used > 0 then
            declare
               Used_Counts : Count_Array (0 .. Used - 1);
               Used_Lengths : Length_Array (0 .. Used - 1);
               J : Natural := 0;
            begin
               for S in 0 .. Last loop
                  if Counts (S) > 0 then
                     Used_Counts (J) := Counts (S);
                     J := J + 1;
                  end if;
               end loop;
               Code_Lengths (Used_Counts, Used_Lengths);
               J := 0;
               for S in 0 .. Last loop
                  if Counts (S) > 0 then
                     Lengths (S) := Used_Lengths (J);
                     J := J + 1;
                  end if;
               end loop;
            end;
         end if;
         Canonical_Codes (Lengths, Codes);
         Put (Buffer, Pos, Unsigned_64 (Last), Category_Bits);
         for L of Lengths loop
            Put (Buffer, Pos, Unsigned_64 (L), Length_Bits);
         end loop;
         Side_Bits := Side_Bits + Category_Bits + Lengths'Length * Length_Bits;
         for V of Data loop
            declare
               B : constant Natural := Bit_Length (V);
            begin
               Put (Buffer, Pos, Codes (B), Lengths (B));
               if B > 0 then
                  Put (Buffer, Pos, (if V < 0 then 1 else 0), 1);
                  Put (Buffer, Pos, Magnitude (V) - Shift_Left (1, B - 1), B - 1);
               end if;
            end;
         end loop;
      end;
   end Put_Bit_Length;

   procedure Get_Bit_Length (Buffer : Byte_Array; Pos : in out Natural; Data : out Value_Array) is
      Field, Sign, Low : Unsigned_64;
      Size : Natural := 0;
   begin
      Get (Buffer, Pos, Field, Category_Bits);
      declare
         Lengths : Length_Array (0 .. Natural (Field));
      begin
         for L of Lengths loop
            Get (Buffer, Pos, Field, Length_Bits);
            L := Natural (Field);
            if L > 0 then
               Size := Size + 1;
            end if;
         end loop;
         declare
            Table : Canonical_Decoding.Table (Size);
            Index : Positive := 1;
            B : Long_Long_Integer;
         begin
            for L of Lengths loop
               if L > 0 then
                  Table.Counts (L) := Table.Counts (L) + 1;
                  Table.Last_Length := Natural'Max (Table.Last_Length, L);
               end if;
            end loop;
            for Len in 1 .. Table.Last_Length loop
               for S in Lengths'Range loop
                  if Lengths (S) = Len then
                     Table.Symbols (Index) := Long_Long_Integer (S);
                     Index := Index + 1;
                  end if;
               end loop;
            end loop;
            for V of Data loop
               Get_Value (Buffer, Pos, Table, B);
               if B = 0 then
                  V := 0;
               else
                  Get (Buffer, Pos, Sign, 1);
                  Get (Buffer, Pos, Low, Natural (B) - 1);
                  V := Long_Long_Integer (Shift_Left (1, Natural (B) - 1) or Low);
                  if Sign = 1 then
                     V := -V;
                  end if;
               end if;
            end loop;
         end;
      end;
   end Get_Bit_Length;

end Residual_Coders;
