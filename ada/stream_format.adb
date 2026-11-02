package body Stream_Format is

   function From_Integer (I : Long_Long_Integer; S : Natural) return Long_Long_Integer is
   begin
      if I = 0 then
         return 0;
      end if;
      declare
         A : constant Long_Long_Integer := abs I;
         L : Natural := 0;
      begin
         while 2**L <= A loop
            L := L + 1;
         end loop;
         declare
            F : constant Long_Long_Integer := (if L <= 24 then A * 2**(24 - L) else A / 2**(L - 24));
            E : constant Long_Long_Integer := Long_Long_Integer (L) - 1 - Long_Long_Integer (S) + 127;
         begin
            return Ordered ((if I < 0 then 2**31 else 0) + E * 2**23 + (F - 2**23));
         end;
      end;
   end From_Integer;

end Stream_Format;
