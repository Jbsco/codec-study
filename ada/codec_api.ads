--  The stream interface of the block codec for C callers: versions, an encoder from interleaved integer samples to a
--  stream, and a decoder from a stream back to them. include/blockcodec.h declares the same functions.
with Interfaces; use Interfaces;
with Interfaces.C; use Interfaces.C;
with System;

package Codec_Api is

   Api_Version : constant := 1;

   --  The layout of blkc_info: the audio a stream holds.
   type Md5_Bytes is array (0 .. 15) of Unsigned_8 with Convention => C;
   type Info is record
      Channels, Rate, Depth, Valid_Bits : Integer_32;
      Frames : Integer_64;
      Channel_Mask : Unsigned_32;
      Is_Float : Integer_32;
      Audio_Md5 : Md5_Bytes;
   end record
     with Convention => C;

   --  The layout of blkc_damage: what a decode found.
   type Damage_Report is record
      Lost_Frames : Integer_64;
      Bad_Groups, Bad_Block_Crcs, Blocks_Ok, Audio_Md5 : Integer_32;
   end record
     with Convention => C;

   function Api_Version_Of return int
     with Export, Convention => C, External_Name => "blkc_api_version";

   function Format_Version_Of return int
     with Export, Convention => C, External_Name => "blkc_format_version";

   function Encode_Bound (Frames : Integer_64; Channels : Integer_32) return Integer_64
     with Export, Convention => C, External_Name => "blkc_encode_bound";

   function Encode (Samples : System.Address; Audio : access constant Info; Level, Threads : Integer_32;
                    Stream : System.Address; Capacity : Integer_64) return Integer_64
     with Export, Convention => C, External_Name => "blkc_encode";

   function Read_Info (Stream : System.Address; Length : Integer_64; Audio : access Info) return int
     with Export, Convention => C, External_Name => "blkc_read_info";

   function Decode (Stream : System.Address; Length : Integer_64; Samples : System.Address; Capacity_Frames : Integer_64;
                    Report : access Damage_Report) return int
     with Export, Convention => C, External_Name => "blkc_decode";

end Codec_Api;
