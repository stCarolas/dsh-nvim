/**
 * Tree-sitter grammar for the rendered dshchat session buffer.
 *
 * The buffer is a presentation format produced by `lua/dsh/render.lua`, not
 * Markdown source: message headers, rendered Markdown blocks, tool calls and
 * indented tool output. The grammar is line oriented and permissive: any line
 * that matches no marker becomes `text`, so a prompt containing header-looking
 * text cannot make the tree contain ERROR nodes.
 */
module.exports = grammar({
  name: 'dshchat',

  extras: $ => [],

  rules: {
    document: $ => repeat($._line),

    _line: $ => choice(
      $.title,
      $._user_message,
      $._assistant_message,
      $.user_header,
      $.assistant_header,
      $.tool_exchange,
      $.tool_call,
      $.code_block,
      $.rule,
      $.quote,
      $.task,
      $.bullet,
      $.ordered,
      $.error,
      $.notice,
      $.blank,
      $.text
    ),

    // Every line in a Neovim buffer is followed by an EOL once the buffer text
    // is assembled for the parser, including the last one.
    _eol: _ => /\r?\n/,

    title: $ => seq($._title_text, $._eol),
    _title_text: _ => token(prec(4, /#[^\n]*/)),

    user_header: $ => seq($._user_header_text, $._eol),
    _user_header_text: _ => token(prec(5, /▌ You[^\n]*/)),

    assistant_header: $ => seq($._assistant_header_text, $._eol),
    _assistant_header_text: _ => token(prec(5, /▌ Assistant(  \(interrupted\))?[^\n]*/)),

    // The first line of text after a header is the message's entry point: the
    // prompt the user typed, or the opening line of the assistant reply. When
    // that line is not text (a list, code block, blank, …) the header is parsed
    // by itself and the line keeps its own type.
    _user_message: $ => prec(1, seq($.user_header, $.user_prompt)),
    _assistant_message: $ => prec(1, seq($.assistant_header, $.assistant_message_header)),
    user_prompt: $ => seq($._text, $._eol),
    assistant_message_header: $ => seq($._text, $._eol),

    error: $ => seq(token(prec(5, /✖ [^\n]*/)), $._eol),
    notice: $ => seq(token(prec(5, /· [^\n]*/)), $._eol),

    rule: $ => seq(token(prec(4, /─+/)), $._eol),

    quote: $ => seq(token(prec(4, / *│ [^\n]*/)), $._eol),
    task: $ => seq(token(prec(4, / *[☐☑] [^\n]*/)), $._eol),
    bullet: $ => seq(token(prec(4, / *• [^\n]*/)), $._eol),
    ordered: $ => seq(token(prec(4, / *[0-9]+[.)] [^\n]*/)), $._eol),

    // A tool call is followed by its indented output; when the exchange is
    // still running (no result yet) the call stands alone.
    tool_exchange: $ => seq($.tool_call, $.tool_output_block),
    tool_call: $ => seq(token(prec(4, /  ⚙ [^\n]*/)), $._eol),
    tool_output_block: $ => prec.right(repeat1($.tool_output)),
    tool_output: $ => seq(token(prec(2, /    [^\n]*/)), $._eol),

    // Rendered fenced code: every line is indented by two spaces.
    code_block: $ => prec.right(repeat1($.code)),
    code: $ => seq(token(prec(1, /  [^\n]*/)), $._eol),

    blank: $ => $._eol,
    text: $ => seq($._text, $._eol),
    _text: _ => token(prec(-1, /[^\n]+/)),
  },
});
