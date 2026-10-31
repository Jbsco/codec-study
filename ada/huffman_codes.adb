with Ada.Containers.Generic_Array_Sort;

package body Huffman_Codes is

   procedure Sort is new Ada.Containers.Generic_Array_Sort (Natural, Long_Long_Integer, Value_Array);

   type Count_Array_Access is access Count_Array;
   procedure Free is new Ada.Unchecked_Deallocation (Count_Array, Count_Array_Access);
   procedure Free is new Ada.Unchecked_Deallocation (Length_Array, Length_Array_Access);
   procedure Free is new Ada.Unchecked_Deallocation (Code_Array, Code_Array_Access);

   type Leaf is record
      Weight : Natural;
      Symbol : Natural;
   end record;

   function "<" (L, R : Leaf) return Boolean is (L.Weight < R.Weight or else (L.Weight = R.Weight and then L.Symbol < R.Symbol));

   type Leaf_Array is array (Natural range <>) of Leaf;
   type Leaf_Array_Access is access Leaf_Array;
   procedure Free is new Ada.Unchecked_Deallocation (Leaf_Array, Leaf_Array_Access);
   procedure Sort is new Ada.Containers.Generic_Array_Sort (Natural, Leaf, Leaf_Array);

   type Weight_Array is array (Natural range <>) of Long_Long_Integer;
   type Weight_Array_Access is access Weight_Array;
   procedure Free is new Ada.Unchecked_Deallocation (Weight_Array, Weight_Array_Access);

   procedure Code_Lengths (Counts : Count_Array; Lengths : out Length_Array) is
      M : constant Natural := Counts'Length;
   begin
      if M = 1 then
         Lengths := [others => 1];
         return;
      end if;
      declare
         Leaves : Leaf_Array_Access := new Leaf_Array (0 .. M - 1);
         Node_Weight : Weight_Array_Access := new Weight_Array (0 .. M - 2);
         Leaf_Parent : Count_Array_Access := new Count_Array (0 .. M - 1);
         Node_Parent : Count_Array_Access := new Count_Array (0 .. M - 2);
         Depth : Count_Array_Access := new Count_Array (0 .. M - 2);
         Next_Leaf, Next_Node : Natural := 0;
      begin
         for I in 0 .. M - 1 loop
            Leaves (I) := (Weight => Counts (Counts'First + I), Symbol => I);
         end loop;
         Sort (Leaves.all);
         --  Leaves and merged nodes both arrive in increasing weight, so two queues replace a heap:
         for K in 0 .. M - 2 loop
            Node_Weight (K) := 0;
            for Unused in 1 .. 2 loop
               if Next_Leaf < M
                 and then (Next_Node = K or else Long_Long_Integer (Leaves (Next_Leaf).Weight) <= Node_Weight (Next_Node))
               then
                  Leaf_Parent (Next_Leaf) := K;
                  Node_Weight (K) := Node_Weight (K) + Long_Long_Integer (Leaves (Next_Leaf).Weight);
                  Next_Leaf := Next_Leaf + 1;
               else
                  Node_Parent (Next_Node) := K;
                  Node_Weight (K) := Node_Weight (K) + Node_Weight (Next_Node);
                  Next_Node := Next_Node + 1;
               end if;
            end loop;
         end loop;
         --  The last node is the root, and every parent comes after its children:
         Depth (M - 2) := 0;
         for J in reverse 0 .. M - 3 loop
            Depth (J) := Depth (Node_Parent (J)) + 1;
         end loop;
         for I in 0 .. M - 1 loop
            Lengths (Lengths'First + Leaves (I).Symbol) := Depth (Leaf_Parent (I)) + 1;
         end loop;
         Free (Leaves);
         Free (Node_Weight);
         Free (Leaf_Parent);
         Free (Node_Parent);
         Free (Depth);
      end;
   end Code_Lengths;

   procedure Canonical_Codes (Lengths : Length_Array; Codes : out Code_Array) is
      Max : constant := Canonical_Decoding.Max_Length;
      Count : array (0 .. Max) of Unsigned_64 := [others => 0];
      Next : array (1 .. Max) of Unsigned_64;
      Code : Unsigned_64 := 0;
   begin
      for L of Lengths loop
         Count (L) := Count (L) + 1;
      end loop;
      Count (0) := 0;
      for Bits in 1 .. Max loop
         Code := Shift_Left (Code + Count (Bits - 1), 1);
         Next (Bits) := Code;
      end loop;
      for I in Lengths'Range loop
         if Lengths (I) = 0 then
            Codes (I) := 0;
         else
            Codes (I) := Next (Lengths (I));
            Next (Lengths (I)) := Next (Lengths (I)) + 1;
         end if;
      end loop;
   end Canonical_Codes;

   procedure Prepare (Book : in out Code_Book; Data : Value_Array) is
      Sorted : Value_Array_Access := new Value_Array'(Data);
      M : Natural := 0;
   begin
      Sort (Sorted.all);
      for I in Sorted'Range loop
         if I = Sorted'First or else Sorted (I) /= Sorted (I - 1) then
            M := M + 1;
         end if;
      end loop;
      Book.Values := new Value_Array (0 .. M - 1);
      Book.Lengths := new Length_Array (0 .. M - 1);
      Book.Codes := new Code_Array (0 .. M - 1);
      if M > 0 then
         declare
            Counts : Count_Array_Access := new Count_Array (0 .. M - 1);
            J : Integer := -1;
         begin
            for I in Sorted'Range loop
               if I = Sorted'First or else Sorted (I) /= Sorted (I - 1) then
                  J := J + 1;
                  Book.Values (J) := Sorted (I);
                  Counts (J) := 0;
               end if;
               Counts (J) := Counts (J) + 1;
            end loop;
            Code_Lengths (Counts.all, Book.Lengths.all);
            Canonical_Codes (Book.Lengths.all, Book.Codes.all);
            Free (Counts);
         end;
      end if;
      Free (Sorted);
   end Prepare;

   function Longest (Book : Code_Book) return Natural is
      Result : Natural := 0;
   begin
      if Book.Lengths /= null then
         for L of Book.Lengths.all loop
            Result := Natural'Max (Result, L);
         end loop;
      end if;
      return Result;
   end Longest;

   --  The longest code length, the number of codes of each length, then the values of each length in
   --  ascending order: the first as a zigzag gamma code, the rest as gamma codes of the step from the last.
   procedure Write_Table (Book : Code_Book; Buffer : in out Byte_Array; Pos : in out Natural) is
      Start : constant Natural := Pos;
      Last : constant Natural := Longest (Book);
      Per_Length : array (0 .. Last) of Natural := [others => 0];
      Next : array (1 .. Last + 1) of Natural;
      Order : Count_Array_Access := new Count_Array (Book.Values'Range);
   begin
      Put_Gamma (Buffer, Pos, Unsigned_64 (Last) + 1);
      for L of Book.Lengths.all loop
         Per_Length (L) := Per_Length (L) + 1;
      end loop;
      for L in 1 .. Last loop
         Put_Gamma (Buffer, Pos, Unsigned_64 (Per_Length (L)) + 1);
      end loop;
      Next (1) := 0;
      for L in 2 .. Last + 1 loop
         Next (L) := Next (L - 1) + Per_Length (L - 1);
      end loop;
      for I in Book.Values'Range loop
         Order (Next (Book.Lengths (I))) := I;
         Next (Book.Lengths (I)) := Next (Book.Lengths (I)) + 1;
      end loop;
      for K in Order'Range loop
         if K = Order'First or else Book.Lengths (Order (K - 1)) /= Book.Lengths (Order (K)) then
            Put_Gamma (Buffer, Pos, Zigzag (Book.Values (Order (K))) + 1);
         else
            Put_Gamma (Buffer, Pos, Unsigned_64 (Book.Values (Order (K)) - Book.Values (Order (K - 1))));
         end if;
      end loop;
      Free (Order);
      Side_Bits := Side_Bits + (Pos - Start);
   end Write_Table;

   procedure Put_Value (Book : Code_Book; Value : Long_Long_Integer; Buffer : in out Byte_Array; Pos : in out Natural) is
      Lo : Natural := Book.Values'First;
      Hi : Natural := Book.Values'Last;
   begin
      while Lo < Hi loop
         declare
            Mid : constant Natural := Lo + (Hi - Lo) / 2;
         begin
            if Book.Values (Mid) < Value then
               Lo := Mid + 1;
            else
               Hi := Mid;
            end if;
         end;
      end loop;
      pragma Assert (Book.Values (Lo) = Value);
      Put (Buffer, Pos, Book.Codes (Lo), Book.Lengths (Lo));
   end Put_Value;

   procedure Clear (Book : in out Code_Book) is
   begin
      Free (Book.Values);
      Free (Book.Lengths);
      Free (Book.Codes);
   end Clear;

   procedure Read_Table (Buffer : Byte_Array; Pos : in out Natural; Table : out Table_Access) is
      N : Unsigned_64;
      Last : Natural;
      Counts : Canonical_Decoding.Count_Array := [others => 0];
      Size : Natural := 0;
      Index : Positive := 1;
   begin
      Get_Gamma (Buffer, Pos, N);
      Last := Natural (N - 1);
      for L in 1 .. Last loop
         Get_Gamma (Buffer, Pos, N);
         Counts (L) := Natural (N - 1);
         Size := Size + Counts (L);
      end loop;
      Table := new Canonical_Decoding.Table (Size);
      Table.Last_Length := Last;
      Table.Counts := Counts;
      for L in 1 .. Last loop
         for C in 1 .. Counts (L) loop
            Get_Gamma (Buffer, Pos, N);
            Table.Symbols (Index) := (if C = 1 then Unzigzag (N - 1) else Table.Symbols (Index - 1) + Long_Long_Integer (N));
            Index := Index + 1;
         end loop;
      end loop;
   end Read_Table;

   procedure Get_Value (Buffer : Byte_Array; Pos : in out Natural; Table : Canonical_Decoding.Table; Value : out Long_Long_Integer) is
      use type Canonical_Decoding.Status_Type;
      Status : Canonical_Decoding.Status_Type;
   begin
      Canonical_Decoding.Decode (Buffer, Pos, Table, Value, Status);
      if Status /= Canonical_Decoding.Success then
         raise Program_Error with "Huffman decoding: " & Status'Image;
      end if;
   end Get_Value;

   procedure Encode (Data : Value_Array; Buffer : in out Byte_Array; Pos : in out Natural) is
      Book : Code_Book;
   begin
      Prepare (Book, Data);
      Write_Table (Book, Buffer, Pos);
      for V of Data loop
         Put_Value (Book, V, Buffer, Pos);
      end loop;
      Clear (Book);
   end Encode;

   procedure Decode (Buffer : Byte_Array; Pos : in out Natural; Data : out Value_Array) is
      Table : Table_Access;
   begin
      Read_Table (Buffer, Pos, Table);
      for V of Data loop
         Get_Value (Buffer, Pos, Table.all, V);
      end loop;
      Free (Table);
   end Decode;

   procedure Put_Gamma (Buffer : in out Byte_Array; Pos : in out Natural; N : Unsigned_64) is
      Bits : Natural := 1;
   begin
      while Bits < 64 and then Shift_Right (N, Bits) > 0 loop
         Bits := Bits + 1;
      end loop;
      Put (Buffer, Pos, 0, Bits - 1);
      Put (Buffer, Pos, N, Bits);
   end Put_Gamma;

   procedure Get_Gamma (Buffer : Byte_Array; Pos : in out Natural; N : out Unsigned_64) is
      Zeros : Natural := 0;
      Bit : Unsigned_64;
   begin
      loop
         Get (Buffer, Pos, Bit, 1);
         exit when Bit = 1;
         Zeros := Zeros + 1;
      end loop;
      Get (Buffer, Pos, N, Zeros);
      N := Shift_Left (1, Zeros) or N;
   end Get_Gamma;

   function Zigzag (V : Long_Long_Integer) return Unsigned_64 is
     (if V >= 0 then 2 * Unsigned_64 (V) else 2 * Unsigned_64 (-(V + 1)) + 1);

   function Unzigzag (U : Unsigned_64) return Long_Long_Integer is
     (if U mod 2 = 0 then Long_Long_Integer (U / 2) else -Long_Long_Integer (U / 2) - 1);

end Huffman_Codes;
