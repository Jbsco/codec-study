--  Check Float_Bits on every 32-bit pattern: Widen agrees with the hardware's 32 to 64-bit conversion for every value
--  that is not a NaN, and Narrow gives every pattern back from its widening as exact. Then 64-bit patterns with low
--  fraction bits set are reported inexact.
with Ada.Text_IO; use Ada.Text_IO;
with Ada.Unchecked_Conversion;
with Float_Bits; use Float_Bits;
with Interfaces; use Interfaces;

procedure Float_Bits_Test is
   function To_Single is new Ada.Unchecked_Conversion (Unsigned_32, IEEE_Float_32);
   function From_Double is new Ada.Unchecked_Conversion (IEEE_Float_64, Unsigned_64);
   Wrong_Widen, Wrong_Narrow, Wrong_Inexact : Natural := 0;
   S : Unsigned_32 := 0;
   Back : Unsigned_32;
   Exact : Boolean;
begin
   loop
      declare
         D : constant Unsigned_64 := Widen (S);
         Nan : constant Boolean := (S and 16#7F80_0000#) = 16#7F80_0000# and then (S and 16#7F_FFFF#) /= 0;
      begin
         if not Nan and then D /= From_Double (IEEE_Float_64 (To_Single (S))) then
            Wrong_Widen := Wrong_Widen + 1;
         end if;
         Narrow (D, Back, Exact);
         if not Exact or else Back /= S then
            Wrong_Narrow := Wrong_Narrow + 1;
         end if;
         if (S and 16#7F80_0000#) /= 16#7F80_0000# and then (S and 16#7FFF_FFFF#) /= 0 then
            Narrow (D or 1, Back, Exact);
            if Exact then
               Wrong_Inexact := Wrong_Inexact + 1;
            end if;
         end if;
      end;
      exit when S = Unsigned_32'Last;
      S := S + 1;
   end loop;
   Put_Line ("float_bits: widen" & Wrong_Widen'Image & " wrong, narrow" & Wrong_Narrow'Image & " wrong, inexact"
             & Wrong_Inexact'Image & " wrong, every 32-bit pattern");
   if Wrong_Widen + Wrong_Narrow + Wrong_Inexact > 0 then
      raise Program_Error with "float_bits check failed";
   end if;
end Float_Bits_Test;
