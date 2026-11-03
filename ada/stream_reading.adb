with Ada.Unchecked_Deallocation;
with Interfaces; use Interfaces;
with Checksums;

package body Stream_Reading is

   use Ada.Strings.Unbounded;

   procedure Read_Header (Stream : Byte_Array; H : out Header) is
      Bits : constant Natural := Stream'Length * 8;
      Pos : Natural := 32;
      Field : Unsigned_64 := 0;
      Ok : Boolean := Stream'Length >= 4 and then Stream (0 .. 3) = Magic;

      --  Read the next Width bits into Field, or fail the header when fewer remain.
      procedure Take (Width : Field_Width) is
      begin
         if Ok and then Width <= Bits - Pos then
            Get (Stream, Pos, Field, Width);
         else
            Ok := False;
            Field := 0;
         end if;
      end Take;

      function Small (Limit : Unsigned_64) return Natural is (if Field <= Limit then Natural (Field) else 0);
   begin
      H := (others => <>);
      H.Seeks := new Seek_List (1 .. 0);
      Take (8);
      Ok := Ok and then Field = Version;
      Take (8);
      Ok := Ok and then Field <= 1;
      H.Independent := Field = 1;
      Take (32);
      Ok := Ok and then Field <= Unsigned_64 (Natural'Last);
      H.Rate := Small (Unsigned_64 (Natural'Last));
      --  A 64-bit frame count; this reader holds the whole output in memory, so it takes up to Natural'Last.
      Take (64);
      Ok := Ok and then Field <= Unsigned_64 (Natural'Last);
      H.Frames := Small (Unsigned_64 (Natural'Last));
      Take (8);
      H.Channels := Small (Max_Channels);
      Take (8);
      H.Depth := Small (64);
      Take (8);
      H.Valid_Bits := Small (64);
      Take (8);
      Ok := Ok and then Field <= 1;
      H.Is_Float := Field = 1;
      Take (32);
      H.Channel_Mask := Long_Long_Integer (Field);
      for I in H.Audio_Md5'Range loop
         Take (8);
         H.Audio_Md5 (I) := Byte (Field mod 256);
      end loop;
      Ok := Ok and then H.Channels >= 1
        and then (if H.Is_Float then H.Depth in 32 | 64 else H.Depth in 8 | 16 | 24 | 32)
        and then H.Valid_Bits in 1 .. H.Depth and then (if H.Is_Float then H.Valid_Bits = H.Depth);
      if H.Is_Float then
         for C in 1 .. H.Channels loop
            Take (8);
            Ok := Ok and then Field in 1 | 2;
            H.Modes (C) := Small (2);
            Take (8);
            Ok := Ok and then Field <= 31;
            H.Scales (C) := Small (31);
         end loop;
      end if;
      Take (8);
      for Unused in 1 .. Small (255) loop
         declare
            Kind, Len, Block_End : Natural;
         begin
            Take (8);
            Kind := Small (255);
            Take (24);
            Len := Small (2**24 - 1);
            exit when not Ok or else Len > (Bits - Pos) / 8;
            Block_End := Pos + 8 * Len;
            if Kind = Tag_Block then
               declare
                  Q : Natural := Pos;
                  Text_Length : Unsigned_64;
                  Ch : Unsigned_64;
               begin
                  while Ok and then Q < Block_End loop
                     if Block_End - Q < 16 then
                        Ok := False;
                     else
                        Get (Stream, Q, Text_Length, 16);
                        if Natural (Text_Length) > (Block_End - Q) / 8 then
                           Ok := False;
                        else
                           H.Tag_Count := H.Tag_Count + 1;
                           Append (H.Tags, (if H.Tag_Count > 1 then ", " else ""));
                           for Unused_Char in 1 .. Natural (Text_Length) loop
                              Get (Stream, Q, Ch, 8);
                              Append (H.Tags, Character'Val (Ch));
                           end loop;
                        end if;
                     end if;
                  end loop;
               end;
            elsif Kind = Source_Block and then H.Source = null then
               H.Source := new Byte_Array'(Stream (Pos / 8 .. Pos / 8 + Len - 1));
            elsif Kind = Seek_Block then
               Ok := Ok and then Len mod 12 = 0;
               if Ok then
                  H.Seeks := new Seek_List (1 .. Len / 12);
                  for E of H.Seeks.all loop
                     Take (32);
                     Ok := Ok and then Field <= Unsigned_64 (H.Frames);
                     E.Frame := Small (Unsigned_64 (Natural'Last));
                     Take (64);
                     E.Offset := Small (Unsigned_64 (Natural'Last));
                  end loop;
               end if;
            end if;
            Pos := Block_End;
         end;
      end loop;
      Ok := Ok and then Bits - Pos >= 16
        and then Checksums.Matches (Stream, Pos / 8, Checksums.Of_Bytes (Stream (0 .. Pos / 8 - 1)));
      H.First_Group := Pos / 8 + 2;
      H.Ok := Ok;
   end Read_Header;

   --  The group header at Offset: its byte length, first frame, frame count, leaves and the position of its block
   --  table. Ok when the sync word, the fields and the CRC are all right.
   procedure Parse_Group (Stream : Byte_Array; H : Header; Offset : Natural; Group_Length, Group_First, Group_Count : out Natural;
                          L : out Leaf_List; Leaf_Count, Table_At : out Natural; Ok : out Boolean) is
      Bits : constant Natural := Stream'Length * 8;
      Field : Unsigned_64;
      P : Natural := Offset * 8;
      Short : Boolean := False;

      procedure Read (Width : Field_Width) is
      begin
         if Width <= Bits - P then
            Get (Stream, P, Field, Width);
         else
            Short := True;
            Field := 0;
         end if;
      end Read;

      procedure Walk (First, Level : Natural) is
      begin
         if Short then
            return;
         end if;
         if not Whole (First, Level, Group_First + Group_Count) then
            Walk (First, Level + 1);
            return;
         end if;
         if Level < Top then
            Read (1);
            if Field = 1 then
               Walk (First, Level + 1);
               Walk (First + Max_Block / 2**(Level + 1), Level + 1);
               return;
            end if;
         end if;
         if Leaf_Count > L'Last then
            Short := True;
            return;
         end if;
         L (Leaf_Count).First := First;
         L (Leaf_Count).Count := Natural'Min (First + Max_Block / 2**Level, Group_First + Group_Count) - First;
         for Pr in 1 .. H.Channels / 2 loop
            Read (2);
            L (Leaf_Count).Modes (Pr) := Natural (Field);
         end loop;
         Leaf_Count := Leaf_Count + 1;
      end Walk;
   begin
      Ok := False;
      Leaf_Count := 0;
      Table_At := 0;
      Group_Length := 0;
      Group_First := 0;
      Group_Count := 0;
      L := [others => (0, 0, [others => 0])];
      if Offset > Stream'Length or else Group_Head + 2 > Stream'Length - Offset then
         return;
      end if;
      Get (Stream, P, Field, 16);
      if Field /= Sync then
         return;
      end if;
      Get (Stream, P, Field, 24);
      Group_Length := Natural (Field);
      Get (Stream, P, Field, 32);
      if Field > Unsigned_64 (H.Frames) then
         return;
      end if;
      Group_First := Natural (Field);
      Get (Stream, P, Field, 16);
      Group_Count := Natural (Field);
      if Group_Length < Group_Head + 2 or else Group_Length > Stream'Length - Offset or else Group_Count = 0
        or else Group_Count > Max_Block or else Group_First + Group_Count > H.Frames
      then
         return;
      end if;
      Walk (Group_First, 0);
      if Short then
         return;
      end if;
      P := (P + 7) / 8 * 8;
      Table_At := P / 8;
      if Table_At + 4 * Leaf_Count * H.Channels + 2 > Offset + Group_Length then
         return;
      end if;
      P := P + 32 * Leaf_Count * H.Channels;
      Ok := Checksums.Matches (Stream, P / 8, Checksums.Of_Bytes (Stream (Offset .. P / 8 - 1)));
   end Parse_Group;

   function New_Scratch (H : Header) return Scratch is
      S : Scratch;
   begin
      for C in 1 .. H.Channels loop
         S.Got (C) := new Sample_Array'(0 .. Max_Block - 1 => 0);
      end loop;
      S.Derived := new Sample_Array'(0 .. Max_History - 1 => 0);
      return S;
   end New_Scratch;

   --  Decode the group at Offset into Buf, reading earlier samples back to frame Floor at most. Ok when the
   --  header was right and the blocks filled the group exactly. A block whose CRC fails is counted and decoded
   --  anyway; a block that does not decode is counted and left as zeros.
   procedure Decode_Group (Stream : Byte_Array; H : Header; Offset : Natural; Buf : in out Channel_Buffers; Floor : Natural;
                           Work : in out Scratch; D : in out Damage; Group_Length, Group_First, Group_Count : out Natural;
                           Ok : out Boolean) is
      L : Leaf_List;
      Leaf_Count, Table_At : Natural;
      Field : Unsigned_64;
      Pairs : constant Natural := H.Channels / 2;
   begin
      Parse_Group (Stream, H, Offset, Group_Length, Group_First, Group_Count, L, Leaf_Count, Table_At, Ok);
      if not Ok then
         return;
      end if;
      declare
         P : Natural := Table_At * 8;
         Block_At : Natural := Table_At + 4 * Leaf_Count * H.Channels + 2;
         Used : Natural;
         Status : Status_Type;
      begin
         for I in 0 .. Leaf_Count - 1 loop
            declare
               First : constant Natural := L (I).First;
               Size_Of : constant Natural := L (I).Count;
               From : constant Natural := Natural'Max (Floor, First - Max_History);
            begin
               for C in 1 .. H.Channels loop
                  declare
                     S : constant Positive := Coded_Signal (C, L (I).Modes, H.Channels);
                     Size : Natural;
                  begin
                     Get (Stream, P, Field, 16);
                     Size := Natural (Field);
                     if Size > Offset + Group_Length - Block_At then
                        Ok := False;
                        return;
                     end if;
                     if not Checksums.Matches (Stream, P / 8, Checksums.Of_Bytes (Stream (Block_At .. Block_At + Size - 1))) then
                        D.Bad_Crcs := D.Bad_Crcs + 1;
                     end if;
                     P := P + 16;
                     if S <= H.Channels then
                        Decode (Stream (Block_At .. Block_At + Size - 1), Buf (S) (From .. First - 1), Signal_Depth (H, S),
                                Work.Got (C) (0 .. Size_Of - 1), Used, Status);
                     else
                        declare
                           A : constant Positive := 2 * Pair_Of (C, Pairs) - 1;
                        begin
                           for K in From .. First - 1 loop
                              Work.Derived (K - From) :=
                                (if S = Pair_Signal (Pair_Of (C, Pairs), 3, H.Channels) then Half_Down (Buf (A) (K) + Buf (A + 1) (K))
                                 else Buf (A) (K) - Buf (A + 1) (K));
                           end loop;
                           Decode (Stream (Block_At .. Block_At + Size - 1), Work.Derived (0 .. First - From - 1), Signal_Depth (H, S),
                                   Work.Got (C) (0 .. Size_Of - 1), Used, Status);
                        end;
                     end if;
                     if Status /= Success or else Used /= Size then
                        D.Blocks_Ok := False;
                        if Status /= Success then
                           Work.Got (C) (0 .. Size_Of - 1) := [others => 0];
                        end if;
                     end if;
                     Block_At := Block_At + Size;
                  end;
               end loop;
               for K in 0 .. Size_Of - 1 loop
                  for Pr in 1 .. Pairs loop
                     declare
                        A : constant Long_Long_Integer := Work.Got (2 * Pr - 1) (K);
                        B : constant Long_Long_Integer := Work.Got (2 * Pr) (K);
                        Sum : constant Long_Long_Integer := 2 * A + B mod 2;
                        Left, Right : Long_Long_Integer;
                     begin
                        case L (I).Modes (Pr) is
                           when 0 => Left := A; Right := B;
                           when 1 => Left := A; Right := A - B;
                           when 2 => Left := A + B; Right := B;
                           when others => Left := (Sum + B) / 2; Right := (Sum - B) / 2;
                        end case;
                        --  A sample that damaged blocks rebuild outside the channel's depth is zeroed.
                        if not In_Range (Left, Coded_Depth (H)) or else not In_Range (Right, Coded_Depth (H)) then
                           D.Blocks_Ok := False;
                           Left := (if In_Range (Left, Coded_Depth (H)) then Left else 0);
                           Right := (if In_Range (Right, Coded_Depth (H)) then Right else 0);
                        end if;
                        Buf (2 * Pr - 1) (First + K) := Left;
                        Buf (2 * Pr) (First + K) := Right;
                     end;
                  end loop;
                  for C in 2 * Pairs + 1 .. H.Channels loop
                     Buf (C) (First + K) := Work.Got (C) (K);
                  end loop;
               end loop;
            end;
         end loop;
         Ok := Block_At = Offset + Group_Length;
      end;
   end Decode_Group;

   --  The first offset at or after From that starts a group with a right header, or the stream's length.
   function Next_Sync (Stream : Byte_Array; H : Header; From : Natural) return Natural is
      L : Leaf_List;
      A, B, C, N, T : Natural;
      Ok : Boolean;
   begin
      if Stream'Length >= Group_Head + 2 then
         for P in From .. Stream'Length - Group_Head - 2 loop
            if Natural (Stream (P)) * 256 + Natural (Stream (P + 1)) = Sync then
               Parse_Group (Stream, H, P, A, B, C, L, N, T, Ok);
               if Ok then
                  return P;
               end if;
            end if;
         end loop;
      end if;
      return Stream'Length;
   end Next_Sync;

   procedure Decode_All (Stream : Byte_Array; H : Header; Output : out Channel_Buffers; Lost : out Boolean_Array_Access;
                         D : out Damage; Verify : Boolean := True) is
      Work : Scratch := New_Scratch (H);
      Offset : Natural := H.First_Group;
      Expected : Natural := 0;
      Group_Length, Group_First, Group_Count, Leaf_Count, Table_At : Natural;
      L : Leaf_List;
      Ok : Boolean;
   begin
      D := (others => <>);
      Lost := new Boolean_Array'(0 .. H.Frames - 1 => False);
      for C in 1 .. H.Channels loop
         Output (C) := new Sample_Array'(0 .. H.Frames - 1 => 0);
      end loop;
      while Offset < Stream'Length loop
         Decode_Group (Stream, H, Offset, Output, 0, Work, D, Group_Length, Group_First, Group_Count, Ok);
         if Ok and then Group_First = Expected then
            Offset := Offset + Group_Length;
            Expected := Group_First + Group_Count;
         else
            D.Bad_Groups := D.Bad_Groups + 1;
            Offset := Next_Sync (Stream, H, Offset + 1);
            if Offset < Stream'Length then
               Parse_Group (Stream, H, Offset, Group_Length, Group_First, Group_Count, L, Leaf_Count, Table_At, Ok);
               if Group_First > Expected then
                  D.Lost_Frames := D.Lost_Frames + Group_First - Expected;
                  Lost (Expected .. Group_First - 1) := [others => True];
               end if;
               Expected := Group_First;
            else
               D.Lost_Frames := D.Lost_Frames + H.Frames - Expected;
               Lost (Expected .. H.Frames - 1) := [others => True];
               Expected := H.Frames;
            end if;
         end if;
      end loop;
      if Expected < H.Frames then
         D.Lost_Frames := D.Lost_Frames + H.Frames - Expected;
         Lost (Expected .. H.Frames - 1) := [others => True];
      end if;
      D.Complete := Expected = H.Frames and then D.Bad_Groups = 0;
      if Verify then
         if H.Audio_Md5 = Audio_Digest.Not_Recorded then
            D.Audio := Not_Recorded;
         else
            declare
               function Sample (C : Positive; F : Natural) return Long_Long_Integer is (Wav_Sample (H, Output, C, F));
            begin
               D.Audio := (if Audio_Digest.Md5 (H.Channels, H.Frames, H.Depth, H.Valid_Bits, H.Is_Float, Sample'Access) = H.Audio_Md5
                           then Matches else Differs);
            end;
         end if;
      end if;
   end Decode_All;

   procedure Decode_From (Stream : Byte_Array; H : Header; Target : Natural; Buf : out Channel_Buffers;
                          Floor, Hops, Count, Last_First, Last_Count : out Natural; Ok : out Boolean) is
      Work : Scratch := New_Scratch (H);
      D : Damage;
      Offset : Natural := H.First_Group;
      Group_Length, Leaf_Count, Table_At : Natural := 0;
      L : Leaf_List;
   begin
      Floor := 0;
      Hops := 0;
      Count := 0;
      Last_First := 0;
      Last_Count := 0;
      Ok := True;
      for E of H.Seeks.all loop
         if E.Frame <= Target then
            Offset := E.Offset;
            Floor := E.Frame;
         end if;
      end loop;
      if H.Independent then
         loop
            Parse_Group (Stream, H, Offset, Group_Length, Last_First, Last_Count, L, Leaf_Count, Table_At, Ok);
            exit when not Ok or else Last_First + Last_Count > Target;
            Offset := Offset + Group_Length;
            Hops := Hops + 1;
         end loop;
         Floor := Last_First;
      end if;
      for C in 1 .. H.Channels loop
         Buf (C) := new Sample_Array'(0 .. H.Frames - 1 => 0);
      end loop;
      while Ok loop
         Decode_Group (Stream, H, Offset, Buf, Floor, Work, D, Group_Length, Last_First, Last_Count, Ok);
         exit when not Ok;
         Count := Count + 1;
         Offset := Offset + Group_Length;
         exit when Last_First + Last_Count > Target;
      end loop;
   end Decode_From;

   procedure Free is new Ada.Unchecked_Deallocation (Sample_Array, Sample_Array_Access);

   procedure Start (W : in out Walker; Stream : Byte_Array_Access; H : Header) is
   begin
      W.Stream := Stream;
      W.H := H;
      W.Work := New_Scratch (H);
      W.Base := 0;
      W.Filled := 0;
      W.Offset := H.First_Group;
      W.D := (others => <>);
      for C in 1 .. H.Channels loop
         W.Buf (C) := new Sample_Array'(0 .. Window - 1 => 0);
      end loop;
   end Start;

   --  Move the window so it holds frames From .. Upto, keeping what it holds of them; the rest reads as zeros.
   procedure Cover (W : in out Walker; From, Upto : Natural) is
   begin
      if From >= W.Base and then Upto <= W.Base + Window - 1 then
         return;
      end if;
      for C in 1 .. W.H.Channels loop
         declare
            Old : Sample_Array_Access := W.Buf (C);
            New_Buf : constant Sample_Array_Access := new Sample_Array'(From .. From + Window - 1 => 0);
            Low : constant Natural := Natural'Max (From, Old'First);
            High : constant Integer := Integer'Min (From + Window - 1, Old'Last);
         begin
            if Low <= High then
               New_Buf (Low .. High) := Old (Low .. High);
            end if;
            Free (Old);
            W.Buf (C) := New_Buf;
         end;
      end loop;
      W.Base := From;
   end Cover;

   --  Frames From .. Upto are lost: zero those the window holds and count them.
   procedure Lose (W : in out Walker; From, Upto : Natural) is
      Low : constant Natural := Natural'Max (From, W.Base);
      High : constant Integer := Integer'Min (Upto, W.Base + Window - 1);
   begin
      if Upto < From then
         return;
      end if;
      W.D.Lost_Frames := W.D.Lost_Frames + Upto - From + 1;
      for C in 1 .. W.H.Channels loop
         if Low <= High then
            W.Buf (C) (Low .. High) := [others => 0];
         end if;
      end loop;
   end Lose;

   procedure Fill (W : in out Walker; Upto : Natural);

   procedure Advance (W : in out Walker; Upto : Natural) is
   begin
      if Upto >= W.Filled then
         Fill (W, Upto);
      end if;
   end Advance;

   procedure Fill (W : in out Walker; Upto : Natural) is
      Target : constant Natural := Natural'Min (Upto, W.H.Frames - 1);
      Group_Length, Group_First, Group_Count, Leaf_Count, Table_At : Natural;
      L : Leaf_List;
      Ok : Boolean;
   begin
      while W.Filled <= Target loop
         if W.Offset >= W.Stream'Length then
            Lose (W, W.Filled, W.H.Frames - 1);
            W.Filled := W.H.Frames;
         else
            Parse_Group (W.Stream.all, W.H, W.Offset, Group_Length, Group_First, Group_Count, L, Leaf_Count, Table_At, Ok);
            if Ok and then Group_First = W.Filled then
               Cover (W, Natural'Max (0, Group_First - Max_History), Group_First + Group_Count - 1);
               Decode_Group (W.Stream.all, W.H, W.Offset, W.Buf, 0, W.Work, W.D, Group_Length, Group_First, Group_Count, Ok);
            else
               Ok := False;
            end if;
            if Ok then
               W.Offset := W.Offset + Group_Length;
               W.Filled := Group_First + Group_Count;
            else
               W.D.Bad_Groups := W.D.Bad_Groups + 1;
               --  The next group with a right header that starts at or after the frames already given out.
               loop
                  W.Offset := Next_Sync (W.Stream.all, W.H, W.Offset + 1);
                  exit when W.Offset >= W.Stream'Length;
                  Parse_Group (W.Stream.all, W.H, W.Offset, Group_Length, Group_First, Group_Count, L, Leaf_Count, Table_At, Ok);
                  exit when Group_First >= W.Filled;
               end loop;
               if W.Offset >= W.Stream'Length then
                  Lose (W, W.Filled, W.H.Frames - 1);
                  W.Filled := W.H.Frames;
               else
                  if Group_First > W.Filled then
                     Lose (W, W.Filled, Group_First - 1);
                  end if;
                  W.Filled := Group_First;
               end if;
            end if;
         end if;
      end loop;
      W.D.Complete := W.Filled = W.H.Frames and then W.D.Bad_Groups = 0 and then W.D.Lost_Frames = 0;
   end Fill;

   function Value (W : Walker; C : Positive; F : Natural) return Long_Long_Integer is
     (if F >= W.Base and then F <= W.Base + Window - 1 then W.Buf (C) (F) else 0);

   function Report (W : Walker) return Damage is (W.D);

end Stream_Reading;
