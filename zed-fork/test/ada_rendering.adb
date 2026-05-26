pragma Ada_2012;
with Ada.Text_IO; use Ada.Text_IO;

--  Characterization fixture for the AdaLanguage data formatters. Every local
--  below exercises one rendering case the formatter must get right; the CI
--  runtime test stops at the marked points and dumps `frame variable`, so we
--  can see exactly how GNAT's DWARF (-fgnat-encodings=minimal) renders today
--  and assert the formatter's output as each feature lands.
procedure Ada_Rendering is

   --  Enumerations -----------------------------------------------------------
   type Color is (Red, Green, Blue);

   --  Representation clause: non-contiguous underlying values. The value 16
   --  must still render as "Err", not as a raw integer.
   type Status is (Off, On, Err);
   for Status use (Off => 0, On => 1, Err => 16);

   --  Numeric ----------------------------------------------------------------
   type Byte is mod 256;                       --  modular

   type Bin_Fixed is delta 0.1 range -10.0 .. 10.0;   --  ordinary fixed (binary small)
   type Money     is delta 0.01 digits 10;            --  decimal fixed (decimal scale)

   --  Records ----------------------------------------------------------------
   type Point is record
      X : Integer;
      Y : Float;
   end record;

   --  Discriminated / variant record. With a default discriminant the object
   --  is mutable, so the active alternative is chosen by the runtime
   --  discriminant -- the case the discriminant-aware formatter must read.
   type Shape (Kind : Color := Red) is record
      Tag : Integer;
      case Kind is
         when Red   => R_Val : Integer;
         when Green => G_Val : Float;
         when Blue  => B_Val : Boolean;
      end case;
   end record;

   --  Record with a fixed-point *field*. The scaling formatter must apply for
   --  a Money-typed child of a record, not just for top-level locals. This is
   --  exactly the case the QualType-keyed design (typedef-wrap of each
   --  fixed-point base) was chosen to cover -- the field's ValueObject has no
   --  Variable of its own, so a Variable-keyed lookup would miss it.
   type Bill is record
      Amount   : Money;
      Quantity : Integer;
   end record;

   --  Arrays -----------------------------------------------------------------
   type Int_Array is array (Positive range <>) of Integer;

   --  `Label` and `Slice` are unconstrained array formals: GNAT passes them as
   --  fat pointers (P_ARRAY + P_BOUNDS). The String/slice formatters must
   --  render the text / element list, not the raw descriptor record.
   procedure Show (Label : String; Slice : Int_Array) is
      Total : Integer := 0;
   begin
      for E of Slice loop
         Total := Total + E;
      end loop;
      pragma Inspection_Point (Label, Slice, Total);
      Put_Line (Label & ":" & Integer'Image (Total));   --  bp_show
   end Show;

   --  Locals to inspect ------------------------------------------------------
   Counter : Integer     := 42;
   Ratio   : Float       := 3.5;
   Col     : Color       := Green;
   St      : Status      := Err;          --  underlying value 16
   Mask    : Byte        := 200;
   BF      : Bin_Fixed   := 2.5;
   M       : Money       := 19.99;
   Len     : Natural     := 10;           --  subtype of Integer
   P       : Point       := (X => 7, Y => 2.5);
   Sh      : Shape       := (Kind => Green, Tag => 1, G_Val => 2.5);
   B       : Bill        := (Amount => 9.99, Quantity => 3);  --  nested fixed-point
   Arr     : Int_Array (1 .. 3) := (10, 20, 30);   --  1-based
   Arr5    : Int_Array (5 .. 7) := (50, 60, 70);   --  arbitrary lower bound
   Name    : String      := "Ada";                 --  constrained String

begin
   pragma Inspection_Point
     (Counter, Ratio, Col, St, Mask, BF, M, Len, P, Sh, B, Arr, Arr5, Name);
   Put_Line (Integer'Image (Counter));   --  bp_main
   Show (Name, Arr);
end Ada_Rendering;
