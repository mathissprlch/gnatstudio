; Code-lens runnable above every Ada subprogram body (procedure or function).
; Click to invoke a task tagged "ada-main" (matched against tasks.json /
; debug.json in this directory). Convention follows the built-in Rust
; runnables.scm:
;   - @run marks the lens anchor (positioned on the subprogram's name).
;   - (#set! tag ada-main) sets the runnable tag matched by tasks.
;
; The briot/tree-sitter-ada grammar exposes procedure_specification and
; function_specification as separate node types -- there is no
; subprogram_specification umbrella. Match either inside subprogram_body.
(
  (subprogram_body
    [(procedure_specification name: (_) @run)
     (function_specification  name: (_) @run)])
  (#set! tag ada-main)
)
