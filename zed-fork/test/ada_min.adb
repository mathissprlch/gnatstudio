with Ada.Text_IO;
procedure Main is
   type Rec is record
      A : Integer;
      B : Float;
   end record;
   Counter : Integer := 42;
   R       : Rec := (A => 7, B => 3.5);
   Arr     : array (1 .. 3) of Integer := (10, 20, 30);
begin
   Ada.Text_IO.Put_Line (Integer'Image (Counter));
   Ada.Text_IO.Put_Line (Integer'Image (R.A + Arr (1)));
end Main;
