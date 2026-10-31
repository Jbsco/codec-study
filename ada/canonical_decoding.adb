with Interfaces; use Interfaces;

package body Canonical_Decoding with SPARK_Mode is

   procedure Decode (Input : Byte_Array; Pos : in out Natural; Codes : Table; Value : out Long_Long_Integer; Status : out Status_Type) is
      Code, First : Unsigned_64 := 0;
      Index : Natural := 0;
   begin
      Value := 0;
      for Len in 1 .. Codes.Last_Length loop
         pragma Loop_Invariant (Pos <= Input'Length * 8 and then Index <= Codes.Size);
         if Pos = Input'Length * 8 then
            Status := Truncated_Input;
            return;
         end if;
         Code := Code or Bit_At (Input, Pos);
         Pos := Pos + 1;
         declare
            Count : constant Natural := Codes.Counts (Len);
         begin
            if Count > Codes.Size - Index then
               Status := Bad_Table;
               return;
            end if;
            --  The codes of this length run from First to First + Count - 1:
            if Code >= First and then Code - First < Unsigned_64 (Count) then
               Value := Codes.Symbols (Index + 1 + Natural (Code - First));
               Status := Success;
               return;
            end if;
            Index := Index + Count;
            First := Shift_Left (First + Unsigned_64 (Count), 1);
            Code := Shift_Left (Code, 1);
         end;
      end loop;
      Status := Bad_Code;
   end Decode;

end Canonical_Decoding;
