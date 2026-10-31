--  Code a PCM WAV file with each scheme, decode it again and compare every sample.
--  Usage: audio_huffman <file.wav> [seconds]
with Ada.Command_Line;
with Ada.Real_Time;
with Ada.Strings.Fixed;
with Ada.Text_IO;
with Interfaces; use Interfaces;
with Bit_Streams; use Bit_Streams;
with Huffman_Codes; use Huffman_Codes;
with Predictors; use Predictors;
with Residual_Coders;
with Wav_Files;

procedure Audio_Huffman is
   use Ada.Text_IO;
   use type Ada.Real_Time.Time;

   package Real_Text is new Float_IO (Long_Float);

   Block : constant := 4096;
   Order_Bits : constant := 3;

   type Byte_Array_Access is access Byte_Array;

   type Scheme is (Raw_Huffman, Difference_Huffman, Tiers_16_Start, Tiers_4_Start, Tiers_16_Successive, Tiers_Pairs,
                   Tiers_Pairs_Mean, Fixed_Huffman, Fixed_Bit_Length, Fixed_Rice);

   function Name (S : Scheme) return String is
     (case S is
        when Raw_Huffman => "Huffman on raw samples",
        when Difference_Huffman => "Huffman on first differences",
        when Tiers_16_Start => "Tiers, groups of 16, offset from group start",
        when Tiers_4_Start => "Tiers, groups of 4, offset from group start",
        when Tiers_16_Successive => "Tiers, groups of 16, successive differences",
        when Tiers_Pairs => "Tiers, pairs",
        when Tiers_Pairs_Mean => "Tiers, pairs, offset from mean of both anchors",
        when Fixed_Huffman => "Fixed predictor, Huffman, one table",
        when Fixed_Bit_Length => "Fixed predictor, bit-length Huffman per block",
        when Fixed_Rice => "Fixed predictor, Rice per block");

   procedure Encode_Channel (S : Scheme; X : Value_Array; Buffer : in out Byte_Array; Pos : in out Natural; Finest : out Natural) is
   begin
      Finest := 0;
      case S is
         when Raw_Huffman =>
            Huffman_Codes.Encode (X, Buffer, Pos);
         when Difference_Huffman =>
            declare
               D : Value_Array_Access := new Value_Array (X'Range);
            begin
               for N in X'Range loop
                  D (N) := X (N) - Predict (X, N, 1);
               end loop;
               Huffman_Codes.Encode (D.all, Buffer, Pos);
               Free (D);
            end;
         when Tiers_16_Start => Encode_Tiers (X, 16, From_Start, Buffer, Pos, Finest);
         when Tiers_4_Start => Encode_Tiers (X, 4, From_Start, Buffer, Pos, Finest);
         when Tiers_16_Successive => Encode_Tiers (X, 16, Successive, Buffer, Pos, Finest);
         when Tiers_Pairs => Encode_Tiers (X, 2, From_Start, Buffer, Pos, Finest);
         when Tiers_Pairs_Mean => Encode_Tiers (X, 2, Mean_Of_Anchors, Buffer, Pos, Finest);
         when Fixed_Huffman | Fixed_Bit_Length | Fixed_Rice =>
            declare
               R : Value_Array_Access := new Value_Array (X'Range);
               Lo : Natural := X'First;
            begin
               while Lo <= X'Last loop
                  declare
                     Hi : constant Natural := Natural'Min (Lo + Block - 1, X'Last);
                     Order : constant Fixed_Order := Best_Order (X, Lo, Hi);
                  begin
                     Put (Buffer, Pos, Unsigned_64 (Order), Order_Bits);
                     Side_Bits := Side_Bits + Order_Bits;
                     for N in Lo .. Hi loop
                        R (N) := X (N) - Predict (X, N, Order);
                     end loop;
                     if S = Fixed_Bit_Length then
                        Residual_Coders.Put_Bit_Length (R (Lo .. Hi), Buffer, Pos);
                     elsif S = Fixed_Rice then
                        Residual_Coders.Put_Rice (R (Lo .. Hi), Buffer, Pos);
                     end if;
                     Lo := Hi + 1;
                  end;
               end loop;
               if S = Fixed_Huffman then
                  Huffman_Codes.Encode (R.all, Buffer, Pos);
               end if;
               Free (R);
            end;
      end case;
   end Encode_Channel;

   procedure Decode_Channel (S : Scheme; Buffer : Byte_Array; Pos : in out Natural; X : out Value_Array) is
   begin
      case S is
         when Raw_Huffman =>
            Huffman_Codes.Decode (Buffer, Pos, X);
         when Difference_Huffman =>
            Huffman_Codes.Decode (Buffer, Pos, X);
            for N in X'Range loop
               X (N) := X (N) + Predict (X, N, 1);
            end loop;
         when Tiers_16_Start => Decode_Tiers (Buffer, Pos, 16, From_Start, X);
         when Tiers_4_Start => Decode_Tiers (Buffer, Pos, 4, From_Start, X);
         when Tiers_16_Successive => Decode_Tiers (Buffer, Pos, 16, Successive, X);
         when Tiers_Pairs => Decode_Tiers (Buffer, Pos, 2, From_Start, X);
         when Tiers_Pairs_Mean => Decode_Tiers (Buffer, Pos, 2, Mean_Of_Anchors, X);
         when Fixed_Huffman | Fixed_Bit_Length | Fixed_Rice =>
            declare
               Blocks : constant Natural := (X'Length + Block - 1) / Block;
               Orders : array (0 .. Blocks - 1) of Fixed_Order := [others => 0];
               Field : Unsigned_64;
            begin
               if S = Fixed_Huffman then
                  for O of Orders loop
                     Get (Buffer, Pos, Field, Order_Bits);
                     O := Fixed_Order (Field);
                  end loop;
                  Huffman_Codes.Decode (Buffer, Pos, X);
               end if;
               for B in Orders'Range loop
                  declare
                     Lo : constant Natural := X'First + B * Block;
                     Hi : constant Natural := Natural'Min (Lo + Block - 1, X'Last);
                  begin
                     if S /= Fixed_Huffman then
                        Get (Buffer, Pos, Field, Order_Bits);
                        Orders (B) := Fixed_Order (Field);
                        if S = Fixed_Bit_Length then
                           Residual_Coders.Get_Bit_Length (Buffer, Pos, X (Lo .. Hi));
                        else
                           Residual_Coders.Get_Rice (Buffer, Pos, X (Lo .. Hi));
                        end if;
                     end if;
                     for N in Lo .. Hi loop
                        X (N) := X (N) + Predict (X, N, Orders (B));
                     end loop;
                  end;
               end loop;
            end;
      end case;
   end Decode_Channel;

   procedure Put_Real (Value : Long_Float; Aft : Natural := 2) is
   begin
      Real_Text.Put (Value, Fore => 3, Aft => Aft, Exp => 0);
   end Put_Real;

   function Seconds_Between (A, B : Ada.Real_Time.Time) return Long_Float is (Long_Float (Ada.Real_Time.To_Duration (B - A)));

   Seconds : constant Natural :=
     (if Ada.Command_Line.Argument_Count >= 2 then Natural'Value (Ada.Command_Line.Argument (2)) else 60);
   Input : Wav_Files.Audio;
begin
   Wav_Files.Read (Ada.Command_Line.Argument (1), Seconds, Input);
   Put_Line (Ada.Command_Line.Argument (1));
   Put_Line ((if Input.Is_Float then " 32-bit float," else Input.Depth'Image & "-bit,") & Input.Rate'Image & " Hz,"
             & Input.Channels'Image & " channels," & Natural'Image (Input.Frames / Input.Rate)
             & " s; bits per sample, side information included:");
   declare
      Total : constant Natural := Input.Frames * Input.Channels;
      Buffer : constant Byte_Array_Access := new Byte_Array (0 .. Total * 12 + 1_000_000);
   begin
      for S in Scheme loop
         declare
            Label : constant String := Name (S);
            Pos, Finest, Finest_Total, Bits : Natural := 0;
            Field : Unsigned_64;
            Same : Boolean;
            Start : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
            Encoded : Ada.Real_Time.Time;
         begin
            Side_Bits := 0;
            Put (Buffer.all, Pos, Unsigned_64 (Input.Frames), 32);
            Put (Buffer.all, Pos, Unsigned_64 (Input.Channels), 8);
            Put (Buffer.all, Pos, Unsigned_64 (Input.Depth), 8);
            Put (Buffer.all, Pos, Boolean'Pos (Input.Is_Float), 1);
            for C in 1 .. Input.Channels loop
               Encode_Channel (S, Input.Samples (C).all, Buffer.all, Pos, Finest);
               Finest_Total := Finest_Total + Finest;
            end loop;
            Bits := Pos;
            Encoded := Ada.Real_Time.Clock;

            Pos := 0;
            Get (Buffer.all, Pos, Field, 32);
            Same := Natural (Field) = Input.Frames;
            Get (Buffer.all, Pos, Field, 8);
            Same := Same and then Natural (Field) = Input.Channels;
            Get (Buffer.all, Pos, Field, 8);
            Same := Same and then Natural (Field) = Input.Depth;
            Get (Buffer.all, Pos, Field, 1);
            Same := Same and then (Field = 1) = Input.Is_Float;
            for C in 1 .. Input.Channels loop
               declare
                  Output : Value_Array_Access := new Value_Array (0 .. Input.Frames - 1);
               begin
                  Decode_Channel (S, Buffer.all, Pos, Output.all);
                  Same := Same and then Output.all = Input.Samples (C).all;
                  Free (Output);
               end;
            end loop;
            Same := Same and then Pos = Bits;

            Put ("  " & Label & Ada.Strings.Fixed."*" (48 - Label'Length, ' '));
            Put_Real (Long_Float (Bits) / Long_Float (Total));
            Put (if Same then "  round trip OK" else "  ROUND TRIP FAILED");
            Put (", side");
            Put_Real (Long_Float (Side_Bits) / Long_Float (Total));
            if Finest_Total > 0 then
               Put (", finest tier");
               Put_Real (Long_Float (Finest_Total) / Long_Float (Total));
            end if;
            Put (", encode");
            Put_Real (Seconds_Between (Start, Encoded), 1);
            Put (" s, decode");
            Put_Real (Seconds_Between (Encoded, Ada.Real_Time.Clock), 1);
            Put_Line (" s");
         end;
      end loop;
   end;
end Audio_Huffman;
