--  IEEE bit patterns between 64-bit and 32-bit float. Narrow reports whether the 64-bit value is exactly a 32-bit
--  one; Widen is exact for every 32-bit value, so Narrow (Widen (S)) gives S back.
with Interfaces; use Interfaces;

package Float_Bits is

   procedure Narrow (Double : Unsigned_64; Single : out Unsigned_32; Exact : out Boolean);

   function Widen (Single : Unsigned_32) return Unsigned_64;

end Float_Bits;
