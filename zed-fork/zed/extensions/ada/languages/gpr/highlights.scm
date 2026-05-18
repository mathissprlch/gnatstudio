; GPR (GNAT project file) highlighting for brownts/tree-sitter-gpr.

[
  "project"
  "package"
  "for"
  "use"
  "is"
  "end"
  "case"
  "when"
  "others"
  "type"
  "extends"
  "renames"
  "with"
  "limited"
  "aggregate"
  "library"
  "abstract"
  "external"
  "null"
] @keyword

(comment) @comment
(string_literal) @string
(numeric_literal) @number

(project_declaration
  name: (_) @namespace)
(package_declaration
  name: (_) @namespace)
(typed_string_declaration
  name: (_) @type)
(attribute_declaration
  name: (_) @property)

[ "(" ")" ] @punctuation.bracket
[ "," ";" ":=" "=>" "&" ] @operator
