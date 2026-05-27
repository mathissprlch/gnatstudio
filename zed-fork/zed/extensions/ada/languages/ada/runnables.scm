; Code-lens runnable above every Ada subprogram body (procedure or function).
; Click to invoke a task tagged "ada-main" (matched against tasks.json /
; debug.json in this directory). Convention follows the built-in Rust
; runnables.scm:
;   - @run marks the lens anchor (positioned on the subprogram's name).
;   - (#set! tag ada-main) sets the runnable tag matched by tasks.
;
; The Ada grammar (briot/tree-sitter-ada) -- same shape used by highlights.scm:
;   (subprogram_body (subprogram_specification name: (_) @function))
(
  (subprogram_body
    (subprogram_specification
      name: (_) @run))
  (#set! tag ada-main)
)
