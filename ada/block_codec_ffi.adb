with Bit_Streams; use Bit_Streams;
with Block_Codec; use Block_Codec;

package body Block_Codec_FFI is

   function Encode (Samples : System.Address; Count, Depth : int; Output : System.Address; Capacity : int) return int is
   begin
      if Count not in 1 .. Max_Block or else Depth not in 8 .. 32 or else Capacity < int (Bound (Positive (Count))) then
         return -1;
      end if;
      declare
         X : Sample_Array (0 .. Natural (Count) - 1) with Import, Address => Samples;
         O : Byte_Array (0 .. Natural (Capacity) - 1) with Import, Address => Output;
         Bytes : Natural;
      begin
         if (for some V of X => not In_Range (V, Positive (Depth))) then
            return -1;
         end if;
         Block_Codec.Encode (X, Positive (Depth), O, Bytes);
         return int (Bytes);
      end;
   end Encode;

   function Decode (Input : System.Address; Length, Count, Depth : int; Samples : System.Address) return int is
   begin
      if Count not in 1 .. Max_Block or else Depth not in 8 .. 32 or else Length not in 0 .. 2**24 then
         return -1;
      end if;
      declare
         I : Byte_Array (0 .. Natural (Length) - 1) with Import, Address => Input;
         X : Sample_Array (0 .. Natural (Count) - 1) with Import, Address => Samples;
         Status : Status_Type;
         Used : Natural;
      begin
         Block_Codec.Decode (I, Positive (Depth), X, Used, Status);
         return Status_Type'Pos (Status);
      end;
   end Decode;

end Block_Codec_FFI;
