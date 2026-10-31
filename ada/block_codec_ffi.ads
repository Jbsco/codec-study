--  C entry points to the block codec for callers in other languages. Each call codes one block and touches no
--  shared state, so calls may run on many threads at once.
with Interfaces.C; use Interfaces.C;
with System;

package Block_Codec_FFI is

   --  Encode Count 64-bit samples of Depth bits into Output. Returns the bytes written, or -1 for arguments out
   --  of range.
   function Encode (Samples : System.Address; Count, Depth : int; Output : System.Address; Capacity : int) return int
     with Export, Convention => C, External_Name => "block_encode";

   --  Decode Count samples from Length bytes. Returns 0 on success, 1 for truncated input, 2 for bad data, and
   --  -1 for arguments out of range.
   function Decode (Input : System.Address; Length, Count, Depth : int; Samples : System.Address) return int
     with Export, Convention => C, External_Name => "block_decode";

end Block_Codec_FFI;
