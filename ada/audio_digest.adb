with Float_Bits;
with Interfaces; use Interfaces;

package body Audio_Digest is

   use Ada.Streams;

   procedure Start (H : out Hasher; Depth, Valid_Bits : Positive; Is_Float : Boolean) is
   begin
      H.Context := GNAT.MD5.Initial_Context;
      H.Width := (if Is_Float then Depth / 8 else (Valid_Bits + 7) / 8);
      H.Shift := (if Is_Float then 0 else Depth - Valid_Bits);
      H.Is_Float := Is_Float;
      H.Is_Double := Is_Float and then Depth = 64;
      H.Buffer := [others => 0];
      H.Fill := 0;
   end Start;

   procedure Add (H : in out Hasher; V : Long_Long_Integer) is
      U : Unsigned_64 :=
        (if H.Is_Double then Float_Bits.Widen (Unsigned_32 (if V >= 0 then V else 2**31 - 1 - V))
         elsif H.Is_Float then Unsigned_64 (if V >= 0 then V else 2**31 - 1 - V)
         else Shift_Right_Arithmetic (Unsigned_64'Mod (V), H.Shift));
   begin
      if H.Fill + Stream_Element_Offset (H.Width) > H.Buffer'Last then
         GNAT.MD5.Update (H.Context, H.Buffer (1 .. H.Fill));
         H.Fill := 0;
      end if;
      for Unused in 1 .. H.Width loop
         H.Fill := H.Fill + 1;
         H.Buffer (H.Fill) := Stream_Element (U and 255);
         U := Shift_Right (U, 8);
      end loop;
   end Add;

   procedure Finish (H : in out Hasher; Result : out Digest) is
   begin
      GNAT.MD5.Update (H.Context, H.Buffer (1 .. H.Fill));
      H.Fill := 0;
      declare
         D : constant GNAT.MD5.Binary_Message_Digest := GNAT.MD5.Digest (H.Context);
      begin
         for I in Result'Range loop
            Result (I) := Byte (D (D'First + Stream_Element_Offset (I)));
         end loop;
      end;
   end Finish;

   function Md5 (Channels : Positive; Frames : Natural; Depth, Valid_Bits : Positive; Is_Float : Boolean;
                 Sample : not null access function (C : Positive; F : Natural) return Long_Long_Integer) return Digest is
      H : Hasher;
      Result : Digest;
   begin
      Start (H, Depth, Valid_Bits, Is_Float);
      for F in 0 .. Frames - 1 loop
         for C in 1 .. Channels loop
            Add (H, Sample (C, F));
         end loop;
      end loop;
      Finish (H, Result);
      return Result;
   end Md5;

   function Image (D : Digest) return String is
      Hex : constant String := "0123456789abcdef";
      Text : String (1 .. 32);
   begin
      for I in D'Range loop
         Text (2 * I + 1) := Hex (Natural (D (I)) / 16 + 1);
         Text (2 * I + 2) := Hex (Natural (D (I)) mod 16 + 1);
      end loop;
      return Text;
   end Image;

end Audio_Digest;
