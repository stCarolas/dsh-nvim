; Highlight queries for rendered dshchat buffers.
;
; The renderer already styles lines with extmarks, and those win (priority
; 4096/4100 over Tree-sitter's 100) wherever they exist. These captures use the
; plugin's own groups so the parser is also useful on its own: they are the
; groups a user already overrides via the highlight groups documented in
; `:help dsh-markdown`.

(title) @DshTitle
(user_header) @DshUserHeader
(assistant_header) @DshAssistantHeader
(tool_call) @DshTool
(tool_output) @DshCodeBlock
(code) @DshCodeBlock
(error) @DshError
(notice) @DshNotice
(rule) @DshHr
(quote) @DshQuote
