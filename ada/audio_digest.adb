with Ada.Streams; use Ada.Streams;
with Float_Bits;
with GNAT.MD5;
with Interfaces; use Interfaces;

package body Audio_Digest is

   function Md5 (Channels : Positive; Frames : Natural; Depth, Valid_Bits : Positive; Is_Float : Boolean;
                 Sample : not null access function (C : Positive; F : Natural) return Long_Long_Integer) return Digest is
      Context : GNAT.MD5.Context := GNAT.MD5.Initial_Context;
      Width : constant Positive := (if Is_Float then Depth / 8 else (Valid_Bits + 7) / 8);
      Shift : constant Natural := (if Is_Float then 0 else Depth - Valid_Bits);
      Buffer : Stream_Element_Array (1 .. 65536) := [others => 0];
      Fill : Stream_Element_Offset := 0;
      Result : Digest;
   begin
      for F in 0 .. Frames - 1 loop
         for C in 1 .. Channels loop
            declare
               V : constant Long_Long_Integer := Sample (C, F);
               U : Unsigned_64 :=
                 (if Is_Float and then Depth = 64 then Float_Bits.Widen (Unsigned_32 (if V >= 0 then V else 2**31 - 1 - V))
                  elsif Is_Float then Unsigned_64 (if V >= 0 then V else 2**31 - 1 - V)
                  else Shift_Right_Arithmetic (Unsigned_64'Mod (V), Shift));
            begin
               if Fill + Stream_Element_Offset (Width) > Buffer'Last then
                  GNAT.MD5.Update (Context, Buffer (1 .. Fill));
                  Fill := 0;
               end if;
               for Unused in 1 .. Width loop
                  Fill := Fill + 1;
                  Buffer (Fill) := Stream_Element (U and 255);
                  U := Shift_Right (U, 8);
               end loop;
            end;
         end loop;
      end loop;
      GNAT.MD5.Update (Context, Buffer (1 .. Fill));
      declare
         D : constant GNAT.MD5.Binary_Message_Digest := GNAT.MD5.Digest (Context);
      begin
         for I in Result'Range loop
            Result (I) := Byte (D (D'First + Stream_Element_Offset (I)));
         end loop;
      end;
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
