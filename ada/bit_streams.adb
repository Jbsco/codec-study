package body Bit_Streams with SPARK_Mode is

   function Bit_At (Buffer : Byte_Array; Pos : Natural) return Unsigned_64 is
     (Unsigned_64 ((Buffer (Buffer'First + Pos / 8) / 2**(7 - Pos mod 8)) and 1));

   procedure Put (Buffer : in out Byte_Array; Pos : in out Natural; Value : Unsigned_64; Count : Field_Width) is
   begin
      for K in reverse 0 .. Count - 1 loop
         pragma Loop_Invariant (Pos = Pos'Loop_Entry + (Count - 1 - K));
         declare
            Index : constant Natural := Buffer'First + Pos / 8;
            Mask : constant Byte := 2**(7 - Pos mod 8);
         begin
            if (Shift_Right (Value, K) and 1) = 1 then
               Buffer (Index) := Buffer (Index) or Mask;
            else
               Buffer (Index) := Buffer (Index) and not Mask;
            end if;
         end;
         Pos := Pos + 1;
      end loop;
   end Put;

   procedure Get (Buffer : Byte_Array; Pos : in out Natural; Value : out Unsigned_64; Count : Field_Width) is
   begin
      Value := 0;
      for K in 1 .. Count loop
         pragma Loop_Invariant (Pos = Pos'Loop_Entry + K - 1);
         Value := Shift_Left (Value, 1) or Bit_At (Buffer, Pos);
         Pos := Pos + 1;
      end loop;
   end Get;

end Bit_Streams;
