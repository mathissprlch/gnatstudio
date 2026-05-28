; Ada syntax highlighting queries for tree-sitter-ada (briot/brownts grammar).
;
; The grammar exposes most of Ada 2022. We map node kinds to Zed's standard
; highlight scopes. SPARK aspects (Pre, Post, Loop_Invariant, ...) flow through
; the same paths since they're aspect_clauses on the regular declarations.

; --- Keywords ----------------------------------------------------------------

[
  "abstract"
  "accept"
  "access"
  "aliased"
  "all"
  "array"
  "at"
  "begin"
  "body"
  "case"
  "constant"
  "declare"
  "delay"
  "delta"
  "digits"
  "do"
  "else"
  "elsif"
  "end"
  "entry"
  "exception"
  "exit"
  "for"
  "function"
  "generic"
  "goto"
  "if"
  "in"
  "interface"
  "is"
  "limited"
  "loop"
  "new"
  "not"
  "null"
  "of"
  "others"
  "out"
  "overriding"
  "package"
  "pragma"
  "private"
  "procedure"
  "protected"
  "raise"
  "range"
  "record"
  "renames"
  "requeue"
  "return"
  "reverse"
  "select"
  "separate"
  "some"
  "subtype"
  "synchronized"
  "tagged"
  "task"
  "terminate"
  "then"
  "type"
  "until"
  "use"
  "when"
  "while"
  "with"
] @keyword

; Operators that are spelled as words.
[
  "and"
  "or"
  "xor"
  "mod"
  "rem"
  "abs"
] @keyword.operator

; --- Operators ---------------------------------------------------------------

[
  ":="
  "=>"
  ".."
  "**"
  "<<"
  ">>"
  "<>"
  "&"
  "+"
  "-"
  "*"
  "/"
  "<"
  "<="
  ">"
  ">="
  "="
  "/="
  ":"
] @operator

; --- Punctuation -------------------------------------------------------------

[ "(" ")" ] @punctuation.bracket
[ "," ";" "'" ] @punctuation.delimiter

; --- Literals ----------------------------------------------------------------

(string_literal) @string
(character_literal) @string
(numeric_literal) @number
(comment) @comment

; --- Identifiers -------------------------------------------------------------

(identifier) @variable

; Type references — every `Foo.Bar` in a subtype_mark slot.
(subtype_indication
  (subtype_mark) @type)

; Subprogram declarations and bodies.
(subprogram_specification
  name: (_) @function)
(subprogram_body
  (subprogram_specification name: (_) @function))

; Package names.
(package_declaration
  name: (_) @namespace)
(package_body
  name: (_) @namespace)
(generic_package_declaration
  name: (_) @namespace)

; Type declarations.
(full_type_declaration
  name: (_) @type)
(subtype_declaration
  name: (_) @type)

; Pragmas and aspects (SPARK contracts, conventions, etc.) -- highlight the
; name as an attribute, which most themes render distinctly.
(pragma_g
  name: (_) @attribute)
(aspect_mark) @attribute
