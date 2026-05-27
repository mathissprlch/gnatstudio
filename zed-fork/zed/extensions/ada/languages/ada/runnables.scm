; Code-lens runnable above every Ada subprogram body (procedures and
; functions). Click to invoke a task tagged "ada_main" from this language's
; tasks.json -- Build / Build & Run today; Debug follows when we wire it.
;
; The Ada grammar (briot/tree-sitter-ada) exposes subprogram_body with a
; subprogram_specification child whose `name:` field is the identifier; the
; @ada_main tag is matched by tags in tasks.json, while @_RUN_NAME exports the
; identifier text as $ZED_CUSTOM_RUN_NAME for the task command.
(
  (subprogram_body
    (subprogram_specification
      name: (_) @_RUN_NAME)
  ) @ada_main
)
