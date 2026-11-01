with Bit_Streams; use Bit_Streams;
with Block_Codec; use Block_Codec;

package body Block_Codec_FFI is

   function Encode (Samples : System.Address; Count : int; History : System.Address; History_Count, Depth : int;
                    Lpc_Orders, Precision_From, Adaptive, Adaptive_Code : int; Output : System.Address; Capacity : int) return int is
   begin
      if Count not in 1 .. Max_Block or else History_Count not in 0 .. Max_History or else Depth not in 8 .. 33
        or else Lpc_Orders not in 0 .. 32 or else Precision_From not in 5 .. 15 or else Capacity < int (Bound (Positive (Count)))
      then
         return -1;
      end if;
      declare
         X : Sample_Array (0 .. Natural (Count) - 1) with Import, Address => Samples;
         H : Sample_Array (0 .. Natural (History_Count) - 1) with Import, Address => History;
         O : Byte_Array (0 .. Natural (Capacity) - 1) with Import, Address => Output;
         Bytes : Natural;
      begin
         if (for some V of X => not In_Range (V, Positive (Depth))) or else (for some V of H => not In_Range (V, Positive (Depth))) then
            return -1;
         end if;
         Block_Codec.Encode (X, H, Positive (Depth), (Natural (Lpc_Orders), Positive (Precision_From), Adaptive /= 0, Adaptive_Code /= 0), O, Bytes);
         return int (Bytes);
      end;
   end Encode;

   function Decode (Input : System.Address; Length : int; History : System.Address; History_Count, Count, Depth : int;
                    Samples : System.Address) return int is
   begin
      if Count not in 1 .. Max_Block or else History_Count not in 0 .. Max_History or else Depth not in 8 .. 33
        or else Length not in 0 .. 2**24
      then
         return -1;
      end if;
      declare
         I : Byte_Array (0 .. Natural (Length) - 1) with Import, Address => Input;
         H : Sample_Array (0 .. Natural (History_Count) - 1) with Import, Address => History;
         X : Sample_Array (0 .. Natural (Count) - 1) with Import, Address => Samples;
         Status : Status_Type;
         Used : Natural;
      begin
         if (for some V of H => not In_Range (V, Positive (Depth))) then
            return -1;
         end if;
         Block_Codec.Decode (I, H, Positive (Depth), X, Used, Status);
         return Status_Type'Pos (Status);
      end;
   end Decode;

end Block_Codec_FFI;
