--  A binary range coder with adaptive 12-bit probabilities, in integer arithmetic only, so two implementations
--  write the same bytes: a 32-bit range, a 33-bit low with the carry held back in a cache byte, bytes written
--  as 8-bit fields of the bit stream. The decoder is in SPARK and reads exactly the bytes the encoder wrote.
with Interfaces; use Interfaces;
with Bit_Streams; use Bit_Streams;

package Range_Coding with SPARK_Mode is

   --  The probability of a zero bit, in 4096ths; it moves toward each coded bit by a 32nd of the distance.
   subtype Probability is Natural range 1 .. 4095;
   Half : constant Probability := 2048;
   Rate : constant := 5;
   Top : constant := 2**24;

   type Encoder is record
      Low : Unsigned_64 := 0;
      Span : Unsigned_32 := 16#FFFF_FFFF#;
      Cache : Byte := 0;
      Pending : Natural := 1;
   end record;

   type Decoder is record
      Code : Unsigned_32 := 0;
      Span : Unsigned_32 := 16#FFFF_FFFF#;
   end record;

   procedure Encode_Bit (E : in out Encoder; P : in out Probability; Bit : Boolean; Output : in out Byte_Array; Pos : in out Natural)
     with SPARK_Mode => Off;

   --  A bit with no model, each value equally likely.
   procedure Encode_Direct (E : in out Encoder; Bit : Boolean; Output : in out Byte_Array; Pos : in out Natural)
     with SPARK_Mode => Off;

   --  Write the bytes that let the decoder read every bit coded so far.
   procedure Flush (E : in out Encoder; Output : in out Byte_Array; Pos : in out Natural)
     with SPARK_Mode => Off;

   --  Ok is False when the input ends before the five bytes the decoder starts from.
   procedure Start (D : out Decoder; Input : Byte_Array; Pos : in out Natural; Ok : out Boolean)
     with Pre => Valid_Buffer (Input) and then Pos <= Input'Length * 8,
       Post => Pos <= Input'Length * 8 and then (if Ok then D.Span >= Top);

   --  Ok is False when the input ends before a byte the decoder needs; the bit is then meaningless.
   procedure Decode_Bit (D : in out Decoder; P : in out Probability; Input : Byte_Array; Pos : in out Natural; Bit : out Boolean;
                         Ok : out Boolean)
     with Pre => Valid_Buffer (Input) and then Pos <= Input'Length * 8 and then D.Span >= Top,
       Post => Pos <= Input'Length * 8 and then (if Ok then D.Span >= Top);

   procedure Decode_Direct (D : in out Decoder; Input : Byte_Array; Pos : in out Natural; Bit : out Boolean; Ok : out Boolean)
     with Pre => Valid_Buffer (Input) and then Pos <= Input'Length * 8 and then D.Span >= Top,
       Post => Pos <= Input'Length * 8 and then (if Ok then D.Span >= Top);

end Range_Coding;
