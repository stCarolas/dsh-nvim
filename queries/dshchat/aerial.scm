; Outline symbols for the rendered dshchat session buffer.
;
; Read by outline.nvim through outline-treesitter-provider.nvim, which ports
; aerial.nvim's query format: `@symbol` marks the node that becomes a tree
; entry, `@name` (optional) supplies the label, and `#set! "kind" "..."` gives
; a valid LSP `SymbolKind` name (outline maps that name to its icon).
;
; Only single-line nodes are captured: outline labels an entry with the whole
; node text, so multi-line nodes (code_block, tool_exchange, ...) would render
; as several lines in the sidebar.
;
;   title                    # Session title
;   user_header              ▌ You
;   user_prompt              first line of the prompt
;   assistant_header         ▌ Assistant
;   assistant_message_header   first line of the reply
;   tool_call                  ⚙ tool(args)
;   error / notice             ✖ … / · …

; Session title, the only top-level heading in a transcript.
((title) @symbol @name
  (#set! "kind" "File"))

; Turn markers. They carry no text of their own, so the marker itself is the
; label.
((user_header) @symbol @name
  (#set! "kind" "Namespace"))

((assistant_header) @symbol @name
  (#set! "kind" "Module"))

; Opening line of each turn: the prompt the user typed, or the first line of
; the assistant reply. This is what makes the outline scannable, since the
; markers above are all identical.
((user_prompt) @symbol @name
  (#set! "kind" "String"))

((assistant_message_header) @symbol @name
  (#set! "kind" "String"))

; Tool calls are the interesting navigation points inside a reply; the
; indented output lines that follow stay out of the outline.
((tool_call) @symbol @name
  (#set! "kind" "Method"))

; Errors and notices the harness printed.
((error) @symbol @name
  (#set! "kind" "Event"))

((notice) @symbol @name
  (#set! "kind" "Constant"))
