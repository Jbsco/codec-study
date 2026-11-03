package body Range_Coding with SPARK_Mode is

   --  Move the top byte of Low out, holding it back while a carry could still reach it.
   procedure Shift_Low (E : in out Encoder; Output : in out Byte_Array; Pos : in out Natural) with SPARK_Mode => Off is
   begin
      if E.Low < 16#FF00_0000# or else E.Low >= 2**32 then
         declare
            Carry : constant Byte := Byte (Shift_Right (E.Low, 32) and 1);
         begin
            Put (Output, Pos, Unsigned_64 (E.Cache + Carry), 8);
            for I in 2 .. E.Pending loop
               Put (Output, Pos, Unsigned_64 (Byte'(16#FF#) + Carry), 8);
            end loop;
            E.Pending := 1;
            E.Cache := Byte (Shift_Right (E.Low, 24) and 16#FF#);
         end;
      else
         E.Pending := E.Pending + 1;
      end if;
      E.Low := Shift_Left (E.Low and 16#00FF_FFFF#, 8);
   end Shift_Low;

   procedure Normalize (E : in out Encoder; Output : in out Byte_Array; Pos : in out Natural) with SPARK_Mode => Off is
   begin
      while E.Span < Top loop
         E.Span := Shift_Left (E.Span, 8);
         Shift_Low (E, Output, Pos);
      end loop;
   end Normalize;

   procedure Encode_Bit (E : in out Encoder; P : in out Probability; Bit : Boolean; Output : in out Byte_Array; Pos : in out Natural)
     with SPARK_Mode => Off
   is
      Bound : constant Unsigned_32 := Shift_Right (E.Span, 12) * Unsigned_32 (P);
   begin
      if Bit then
         E.Low := E.Low + Unsigned_64 (Bound);
         E.Span := E.Span - Bound;
         P := P - P / 2**Rate;
      else
         E.Span := Bound;
         P := P + (4096 - P) / 2**Rate;
      end if;
      Normalize (E, Output, Pos);
   end Encode_Bit;

   procedure Encode_Direct (E : in out Encoder; Bit : Boolean; Output : in out Byte_Array; Pos : in out Natural)
     with SPARK_Mode => Off
   is
   begin
      E.Span := Shift_Right (E.Span, 1);
      if Bit then
         E.Low := E.Low + Unsigned_64 (E.Span);
      end if;
      Normalize (E, Output, Pos);
   end Encode_Direct;

   procedure Flush (E : in out Encoder; Output : in out Byte_Array; Pos : in out Natural) with SPARK_Mode => Off is
   begin
      for I in 1 .. 5 loop
         Shift_Low (E, Output, Pos);
      end loop;
   end Flush;

   procedure Start (D : out Decoder; Input : Byte_Array; Pos : in out Natural; Ok : out Boolean) is
      Total : constant Natural := Input'Length * 8;
      B : Unsigned_64;
   begin
      D := (Code => 0, Span => 16#FFFF_FFFF#);
      Ok := False;
      if Total - Pos < 40 then
         return;
      end if;
      for I in 1 .. 5 loop
         pragma Loop_Invariant (Pos <= Total - 8 * (6 - I));
         Get (Input, Pos, B, 8);
         D.Code := Shift_Left (D.Code, 8) or Unsigned_32 (B);
      end loop;
      Ok := True;
   end Start;

   --  Bring the span back above Top, taking a byte into the code for each shift.
   procedure Normalize (D : in out Decoder; Input : Byte_Array; Pos : in out Natural; Ok : out Boolean)
     with Pre => Valid_Buffer (Input) and then Pos <= Input'Length * 8 and then D.Span >= 2**12,
       Post => Pos <= Input'Length * 8 and then (if Ok then D.Span >= Top),
       Inline
   is
      Total : constant Natural := Input'Length * 8;
      B : Unsigned_64;
   begin
      Ok := False;
      while D.Span < Top loop
         pragma Loop_Invariant (Pos <= Total and then D.Span >= 2**12);
         if Total - Pos < 8 then
            return;
         end if;
         Get (Input, Pos, B, 8);
         D.Span := Shift_Left (D.Span, 8);
         D.Code := Shift_Left (D.Code, 8) or Unsigned_32 (B);
      end loop;
      Ok := True;
   end Normalize;

   procedure Decode_Bit (D : in out Decoder; P : in out Probability; Input : Byte_Array; Pos : in out Natural; Bit : out Boolean;
                         Ok : out Boolean)
   is
      Step : constant Unsigned_32 := Shift_Right (D.Span, 12);
      Bound : constant Unsigned_32 := Step * Unsigned_32 (P);
   begin
      pragma Assert (Step >= 2**12 and then Step <= 2**20);
      pragma Assert (Unsigned_64 (Bound) = Unsigned_64 (Step) * Unsigned_64 (P));
      pragma Assert (Long_Long_Integer (Bound) = Long_Long_Integer (Step) * Long_Long_Integer (P));
      pragma Assert (Long_Long_Integer (Step) * (4095 - Long_Long_Integer (P)) >= 0);
      pragma Assert (Long_Long_Integer (Bound) + Long_Long_Integer (Step) <= Long_Long_Integer (Step) * 4096);
      pragma Assert (Long_Long_Integer (Step) * 4096 <= Long_Long_Integer (D.Span));
      pragma Assert (Bound >= Step and then Bound <= D.Span - Step);
      if D.Code < Bound then
         D.Span := Bound;
         Bit := False;
         P := P + (4096 - P) / 2**Rate;
      else
         D.Code := D.Code - Bound;
         D.Span := D.Span - Bound;
         Bit := True;
         P := P - P / 2**Rate;
      end if;
      Normalize (D, Input, Pos, Ok);
   end Decode_Bit;

   procedure Decode_Direct (D : in out Decoder; Input : Byte_Array; Pos : in out Natural; Bit : out Boolean; Ok : out Boolean) is
   begin
      D.Span := Shift_Right (D.Span, 1);
      Bit := D.Code >= D.Span;
      if Bit then
         D.Code := D.Code - D.Span;
      end if;
      Normalize (D, Input, Pos, Ok);
   end Decode_Direct;

end Range_Coding;
