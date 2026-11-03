package body Bit_Streams with SPARK_Mode is

   function Bit_At (Buffer : Byte_Array; Pos : Natural) return Unsigned_64 is
     (Unsigned_64 ((Buffer (Buffer'First + Pos / 8) / 2**(7 - Pos mod 8)) and 1));

   procedure Put (Buffer : in out Byte_Array; Pos : in out Natural; Value : Unsigned_64; Count : Field_Width) is
      Left : Natural := Count;
   begin
      while Left > 0 loop
         pragma Loop_Invariant (Left <= Count and then Pos = Pos'Loop_Entry + (Count - Left));
         pragma Loop_Variant (Decreases => Left);
         declare
            Index : constant Natural := Buffer'First + Pos / 8;
            Avail : constant Positive := 8 - Pos mod 8;
            Take : constant Positive := Natural'Min (Avail, Left);
            Low : constant Unsigned_64 := Shift_Left (1, Take) - 1;
            Field : constant Unsigned_64 := Shift_Left (Shift_Right (Value, Left - Take) and Low, Avail - Take);
            Mask : constant Unsigned_64 := Shift_Left (Low, Avail - Take);
         begin
            Buffer (Index) := Byte (((Unsigned_64 (Buffer (Index)) and not Mask) or Field) and 16#FF#);
            Pos := Pos + Take;
            Left := Left - Take;
         end;
      end loop;
   end Put;

   procedure Get (Buffer : Byte_Array; Pos : in out Natural; Value : out Unsigned_64; Count : Field_Width) is
   begin
      if Count = 0 then
         Value := 0;
      elsif Count <= 56 then
         --  The bytes that hold the field, in one word, then the field shifted down and masked.
         declare
            First : constant Natural := Buffer'First + Pos / 8;
            Skip : constant Natural := Pos mod 8;
            N : constant Positive := (Skip + Count + 7) / 8;
            W : Unsigned_64 := 0;
         begin
            pragma Assert (N <= 8 and then First + N - 1 <= Buffer'Last);
            for I in 0 .. N - 1 loop
               W := Shift_Left (W, 8) or Unsigned_64 (Buffer (First + I));
            end loop;
            Value := Shift_Right (W, 8 * N - Skip - Count) and (Shift_Left (1, Count) - 1);
            pragma Assert (Shift_Right (Value, Count) = 0);
            Pos := Pos + Count;
         end;
      else
         Value := 0;
         for K in 1 .. Count loop
            pragma Loop_Invariant (Pos = Pos'Loop_Entry + K - 1 and then Value < 2**(K - 1));
            Value := Value * 2 + Bit_At (Buffer, Pos);
            Pos := Pos + 1;
         end loop;
      end if;
   end Get;

end Bit_Streams;
