package body Float_Bits is

   procedure Narrow (Double : Unsigned_64; Single : out Unsigned_32; Exact : out Boolean) is
      Sign : constant Unsigned_32 := Unsigned_32 (Shift_Right (Double, 63)) * 2**31;
      Exponent : constant Integer := Integer (Shift_Right (Double, 52) and 16#7FF#);
      Fraction : constant Unsigned_64 := Double and (2**52 - 1);
      Unbiased : constant Integer := Exponent - 1023;
   begin
      Single := Sign;
      Exact := False;
      if Exponent = 16#7FF# then
         Exact := (Fraction and (2**29 - 1)) = 0 and then (Fraction = 0 or else Shift_Right (Fraction, 29) /= 0);
         Single := Sign or 16#7F80_0000# or Unsigned_32 (Shift_Right (Fraction, 29));
      elsif Exponent = 0 then
         Exact := Fraction = 0;
      elsif Unbiased in -126 .. 127 then
         Exact := (Fraction and (2**29 - 1)) = 0;
         Single := Sign or Unsigned_32 (Unbiased + 127) * 2**23 or Unsigned_32 (Shift_Right (Fraction, 29));
      elsif Unbiased in -149 .. -127 then
         declare
            Significand : constant Unsigned_64 := Fraction or 2**52;
            Shift : constant Natural := -97 - Unbiased;
         begin
            Exact := (Significand and (Shift_Left (1, Shift) - 1)) = 0;
            Single := Sign or Unsigned_32 (Shift_Right (Significand, Shift));
         end;
      end if;
   end Narrow;

   function Widen (Single : Unsigned_32) return Unsigned_64 is
      Sign : constant Unsigned_64 := Unsigned_64 (Shift_Right (Single, 31)) * 2**63;
      Exponent : constant Natural := Natural (Shift_Right (Single, 23) and 16#FF#);
      Fraction : constant Unsigned_64 := Unsigned_64 (Single and 16#7F_FFFF#);
   begin
      if Exponent = 16#FF# then
         return Sign or Shift_Left (16#7FF#, 52) or Shift_Left (Fraction, 29);
      elsif Exponent = 0 then
         if Fraction = 0 then
            return Sign;
         end if;
         declare
            Top : Natural := 22;
         begin
            while Shift_Right (Fraction, Top) = 0 loop
               Top := Top - 1;
            end loop;
            return Sign or Shift_Left (Unsigned_64 (Top - 149 + 1023), 52) or (Shift_Left (Fraction, 52 - Top) and (2**52 - 1));
         end;
      else
         return Sign or Shift_Left (Unsigned_64 (Exponent - 127 + 1023), 52) or Shift_Left (Fraction, 29);
      end if;
   end Widen;

end Float_Bits;
