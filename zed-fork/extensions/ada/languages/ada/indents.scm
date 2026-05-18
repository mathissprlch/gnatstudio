; Indent inside compound statements, declarations and parenthesized groups.
; ALS owns the authoritative formatter (gnatformat); this is just used while
; typing before the LSP round-trip lands.

[
  (subprogram_body)
  (package_body)
  (package_declaration)
  (block_statement)
  (if_statement)
  (case_statement)
  (loop_statement)
  (record_definition)
  (parameter_specification)
] @indent

[
  "end"
] @outdent
