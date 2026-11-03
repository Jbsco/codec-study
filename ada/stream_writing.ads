--  Writing the block codec's stream: the search at each level over every node of each group's split tree, the stereo
--  modes of each channel pair, the groups with their block tables and CRCs, and the header with its metadata.
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Audio_Digest;
with Stream_Format; use Stream_Format;
with Wav_Files;

package Stream_Writing is

   Max_Tags : constant := 64;
   type Tag_List is array (1 .. Max_Tags) of Ada.Strings.Unbounded.Unbounded_String;

   --  Seconds between seek points when none are asked for: 1 at level 5, whose adaptive stage trains on the samples
   --  before each block, so a seek decodes from the seek point, and 10 at the other levels.
   function Default_Seek_Every (Level : Natural) return Natural is (if Level = 5 then 1 else 10);

   --  The level, 0 to 5; seconds between seek points, 0 for one segment, -1 for the level's default; whether every
   --  group is a segment; whether channel pairs may take stereo modes; the tags; a file for each group's features,
   --  or null; and how many groups are coded at once.
   type Options is record
      Level : Natural range 0 .. 5 := 4;
      Seek_Every : Integer range -1 .. 86_400 := -1;
      Independent : Boolean := False;
      Pairs : Boolean := True;
      Tag_Count : Natural range 0 .. Max_Tags := 0;
      Tags : Tag_List;
      Features : access Ada.Text_IO.File_Type;
      Threads : Positive := 1;
   end record;

   type Kind_Counts is array (0 .. 12) of Natural;

   --  Bits of the coded blocks by role, and two estimates for LPC blocks: the coefficients in the better of Rice
   --  and Exp-Golomb codes with a per-block parameter, and the warm-up coded at the block's residual rate.
   type Side_Counts is record
      Headers, Coefficients, Warm_Up, Tables, Residuals, Coded_Coefficients, Seeded_Warm_Up : Long_Long_Integer := 0;
   end record;

   type Natural_Array is array (Natural range <>) of Natural;
   type Natural_Array_Access is access Natural_Array;
   type Channel_Naturals is array (1 .. Max_Channels) of Natural;

   --  What the encoder chose and wrote: block kinds and bits by role, stereo modes and leaves per tree level, the
   --  header and framing bytes, each group's byte offset after the header, each channel's float mode and scale, and
   --  the MD5 of the input samples.
   type Statistics is record
      Kinds : Kind_Counts := [others => 0];
      Side : Side_Counts;
      Stereo : Natural_Array (0 .. 3) := [others => 0];
      Leaves : Natural_Array (0 .. Top) := [others => 0];
      Header_Length, Groups, Blocks, Framing, Segment_Span : Natural := 0;
      Group_Starts : Natural_Array_Access;
      Modes, Scales : Channel_Naturals := [others => 0];
      Audio_Md5 : Audio_Digest.Digest := Audio_Digest.Not_Recorded;
   end record;

   --  Code Input into Stream (0 .. Length - 1). Float input becomes integers in Input's samples.
   procedure Encode (Input : in out Wav_Files.Audio; Opt : Options; Stream : out Byte_Array_Access; Length : out Natural;
                     Stats : out Statistics);

   --  Free what Encode allocated in Stats.
   procedure Release (Stats : in out Statistics);

end Stream_Writing;
