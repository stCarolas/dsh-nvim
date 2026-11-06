#include "tree_sitter/parser.h"

#if defined(__GNUC__) || defined(__clang__)
#pragma GCC diagnostic ignored "-Wmissing-field-initializers"
#endif

#define LANGUAGE_VERSION 14
#define STATE_COUNT 48
#define LARGE_STATE_COUNT 4
#define SYMBOL_COUNT 43
#define ALIAS_COUNT 0
#define TOKEN_COUNT 16
#define EXTERNAL_TOKEN_COUNT 0
#define FIELD_COUNT 0
#define MAX_ALIAS_SEQUENCE_LENGTH 2
#define PRODUCTION_ID_COUNT 1

enum ts_symbol_identifiers {
  sym__eol = 1,
  sym__title_text = 2,
  sym__user_header_text = 3,
  sym__assistant_header_text = 4,
  aux_sym_error_token1 = 5,
  aux_sym_notice_token1 = 6,
  aux_sym_rule_token1 = 7,
  aux_sym_quote_token1 = 8,
  aux_sym_task_token1 = 9,
  aux_sym_bullet_token1 = 10,
  aux_sym_ordered_token1 = 11,
  aux_sym_tool_call_token1 = 12,
  aux_sym_tool_output_token1 = 13,
  aux_sym_code_token1 = 14,
  sym__text = 15,
  sym_document = 16,
  sym__line = 17,
  sym_title = 18,
  sym_user_header = 19,
  sym_assistant_header = 20,
  sym__user_message = 21,
  sym__assistant_message = 22,
  sym_user_prompt = 23,
  sym_assistant_message_header = 24,
  sym_error = 25,
  sym_notice = 26,
  sym_rule = 27,
  sym_quote = 28,
  sym_task = 29,
  sym_bullet = 30,
  sym_ordered = 31,
  sym_tool_exchange = 32,
  sym_tool_call = 33,
  sym_tool_output_block = 34,
  sym_tool_output = 35,
  sym_code_block = 36,
  sym_code = 37,
  sym_blank = 38,
  sym_text = 39,
  aux_sym_document_repeat1 = 40,
  aux_sym_tool_output_block_repeat1 = 41,
  aux_sym_code_block_repeat1 = 42,
};

static const char * const ts_symbol_names[] = {
  [ts_builtin_sym_end] = "end",
  [sym__eol] = "_eol",
  [sym__title_text] = "_title_text",
  [sym__user_header_text] = "_user_header_text",
  [sym__assistant_header_text] = "_assistant_header_text",
  [aux_sym_error_token1] = "error_token1",
  [aux_sym_notice_token1] = "notice_token1",
  [aux_sym_rule_token1] = "rule_token1",
  [aux_sym_quote_token1] = "quote_token1",
  [aux_sym_task_token1] = "task_token1",
  [aux_sym_bullet_token1] = "bullet_token1",
  [aux_sym_ordered_token1] = "ordered_token1",
  [aux_sym_tool_call_token1] = "tool_call_token1",
  [aux_sym_tool_output_token1] = "tool_output_token1",
  [aux_sym_code_token1] = "code_token1",
  [sym__text] = "_text",
  [sym_document] = "document",
  [sym__line] = "_line",
  [sym_title] = "title",
  [sym_user_header] = "user_header",
  [sym_assistant_header] = "assistant_header",
  [sym__user_message] = "_user_message",
  [sym__assistant_message] = "_assistant_message",
  [sym_user_prompt] = "user_prompt",
  [sym_assistant_message_header] = "assistant_message_header",
  [sym_error] = "error",
  [sym_notice] = "notice",
  [sym_rule] = "rule",
  [sym_quote] = "quote",
  [sym_task] = "task",
  [sym_bullet] = "bullet",
  [sym_ordered] = "ordered",
  [sym_tool_exchange] = "tool_exchange",
  [sym_tool_call] = "tool_call",
  [sym_tool_output_block] = "tool_output_block",
  [sym_tool_output] = "tool_output",
  [sym_code_block] = "code_block",
  [sym_code] = "code",
  [sym_blank] = "blank",
  [sym_text] = "text",
  [aux_sym_document_repeat1] = "document_repeat1",
  [aux_sym_tool_output_block_repeat1] = "tool_output_block_repeat1",
  [aux_sym_code_block_repeat1] = "code_block_repeat1",
};

static const TSSymbol ts_symbol_map[] = {
  [ts_builtin_sym_end] = ts_builtin_sym_end,
  [sym__eol] = sym__eol,
  [sym__title_text] = sym__title_text,
  [sym__user_header_text] = sym__user_header_text,
  [sym__assistant_header_text] = sym__assistant_header_text,
  [aux_sym_error_token1] = aux_sym_error_token1,
  [aux_sym_notice_token1] = aux_sym_notice_token1,
  [aux_sym_rule_token1] = aux_sym_rule_token1,
  [aux_sym_quote_token1] = aux_sym_quote_token1,
  [aux_sym_task_token1] = aux_sym_task_token1,
  [aux_sym_bullet_token1] = aux_sym_bullet_token1,
  [aux_sym_ordered_token1] = aux_sym_ordered_token1,
  [aux_sym_tool_call_token1] = aux_sym_tool_call_token1,
  [aux_sym_tool_output_token1] = aux_sym_tool_output_token1,
  [aux_sym_code_token1] = aux_sym_code_token1,
  [sym__text] = sym__text,
  [sym_document] = sym_document,
  [sym__line] = sym__line,
  [sym_title] = sym_title,
  [sym_user_header] = sym_user_header,
  [sym_assistant_header] = sym_assistant_header,
  [sym__user_message] = sym__user_message,
  [sym__assistant_message] = sym__assistant_message,
  [sym_user_prompt] = sym_user_prompt,
  [sym_assistant_message_header] = sym_assistant_message_header,
  [sym_error] = sym_error,
  [sym_notice] = sym_notice,
  [sym_rule] = sym_rule,
  [sym_quote] = sym_quote,
  [sym_task] = sym_task,
  [sym_bullet] = sym_bullet,
  [sym_ordered] = sym_ordered,
  [sym_tool_exchange] = sym_tool_exchange,
  [sym_tool_call] = sym_tool_call,
  [sym_tool_output_block] = sym_tool_output_block,
  [sym_tool_output] = sym_tool_output,
  [sym_code_block] = sym_code_block,
  [sym_code] = sym_code,
  [sym_blank] = sym_blank,
  [sym_text] = sym_text,
  [aux_sym_document_repeat1] = aux_sym_document_repeat1,
  [aux_sym_tool_output_block_repeat1] = aux_sym_tool_output_block_repeat1,
  [aux_sym_code_block_repeat1] = aux_sym_code_block_repeat1,
};

static const TSSymbolMetadata ts_symbol_metadata[] = {
  [ts_builtin_sym_end] = {
    .visible = false,
    .named = true,
  },
  [sym__eol] = {
    .visible = false,
    .named = true,
  },
  [sym__title_text] = {
    .visible = false,
    .named = true,
  },
  [sym__user_header_text] = {
    .visible = false,
    .named = true,
  },
  [sym__assistant_header_text] = {
    .visible = false,
    .named = true,
  },
  [aux_sym_error_token1] = {
    .visible = false,
    .named = false,
  },
  [aux_sym_notice_token1] = {
    .visible = false,
    .named = false,
  },
  [aux_sym_rule_token1] = {
    .visible = false,
    .named = false,
  },
  [aux_sym_quote_token1] = {
    .visible = false,
    .named = false,
  },
  [aux_sym_task_token1] = {
    .visible = false,
    .named = false,
  },
  [aux_sym_bullet_token1] = {
    .visible = false,
    .named = false,
  },
  [aux_sym_ordered_token1] = {
    .visible = false,
    .named = false,
  },
  [aux_sym_tool_call_token1] = {
    .visible = false,
    .named = false,
  },
  [aux_sym_tool_output_token1] = {
    .visible = false,
    .named = false,
  },
  [aux_sym_code_token1] = {
    .visible = false,
    .named = false,
  },
  [sym__text] = {
    .visible = false,
    .named = true,
  },
  [sym_document] = {
    .visible = true,
    .named = true,
  },
  [sym__line] = {
    .visible = false,
    .named = true,
  },
  [sym_title] = {
    .visible = true,
    .named = true,
  },
  [sym_user_header] = {
    .visible = true,
    .named = true,
  },
  [sym_assistant_header] = {
    .visible = true,
    .named = true,
  },
  [sym__user_message] = {
    .visible = false,
    .named = true,
  },
  [sym__assistant_message] = {
    .visible = false,
    .named = true,
  },
  [sym_user_prompt] = {
    .visible = true,
    .named = true,
  },
  [sym_assistant_message_header] = {
    .visible = true,
    .named = true,
  },
  [sym_error] = {
    .visible = true,
    .named = true,
  },
  [sym_notice] = {
    .visible = true,
    .named = true,
  },
  [sym_rule] = {
    .visible = true,
    .named = true,
  },
  [sym_quote] = {
    .visible = true,
    .named = true,
  },
  [sym_task] = {
    .visible = true,
    .named = true,
  },
  [sym_bullet] = {
    .visible = true,
    .named = true,
  },
  [sym_ordered] = {
    .visible = true,
    .named = true,
  },
  [sym_tool_exchange] = {
    .visible = true,
    .named = true,
  },
  [sym_tool_call] = {
    .visible = true,
    .named = true,
  },
  [sym_tool_output_block] = {
    .visible = true,
    .named = true,
  },
  [sym_tool_output] = {
    .visible = true,
    .named = true,
  },
  [sym_code_block] = {
    .visible = true,
    .named = true,
  },
  [sym_code] = {
    .visible = true,
    .named = true,
  },
  [sym_blank] = {
    .visible = true,
    .named = true,
  },
  [sym_text] = {
    .visible = true,
    .named = true,
  },
  [aux_sym_document_repeat1] = {
    .visible = false,
    .named = false,
  },
  [aux_sym_tool_output_block_repeat1] = {
    .visible = false,
    .named = false,
  },
  [aux_sym_code_block_repeat1] = {
    .visible = false,
    .named = false,
  },
};

static const TSSymbol ts_alias_sequences[PRODUCTION_ID_COUNT][MAX_ALIAS_SEQUENCE_LENGTH] = {
  [0] = {0},
};

static const uint16_t ts_non_terminal_alias_map[] = {
  0,
};

static const TSStateId ts_primary_state_ids[STATE_COUNT] = {
  [0] = 0,
  [1] = 1,
  [2] = 2,
  [3] = 3,
  [4] = 4,
  [5] = 5,
  [6] = 6,
  [7] = 7,
  [8] = 8,
  [9] = 9,
  [10] = 10,
  [11] = 11,
  [12] = 12,
  [13] = 13,
  [14] = 14,
  [15] = 15,
  [16] = 16,
  [17] = 17,
  [18] = 18,
  [19] = 19,
  [20] = 20,
  [21] = 21,
  [22] = 22,
  [23] = 23,
  [24] = 24,
  [25] = 25,
  [26] = 26,
  [27] = 27,
  [28] = 28,
  [29] = 29,
  [30] = 30,
  [31] = 31,
  [32] = 32,
  [33] = 33,
  [34] = 34,
  [35] = 35,
  [36] = 36,
  [37] = 37,
  [38] = 38,
  [39] = 39,
  [40] = 40,
  [41] = 41,
  [42] = 42,
  [43] = 43,
  [44] = 44,
  [45] = 45,
  [46] = 46,
  [47] = 47,
};

static bool ts_lex(TSLexer *lexer, TSStateId state) {
  START_LEXER();
  eof = lexer->eof(lexer);
  switch (state) {
    case 0:
      if (eof) ADVANCE(2);
      ADVANCE_MAP(
        '\n', 3,
        '\r', 48,
        ' ', 49,
        '#', 4,
        0xb7, 50,
        0x2022, 51,
        0x2500, 24,
        0x2502, 52,
        0x258c, 53,
        0x2716, 54,
        0x2610, 55,
        0x2611, 55,
      );
      if (('0' <= lookahead && lookahead <= '9')) ADVANCE(69);
      if (lookahead != 0) ADVANCE(70);
      END_STATE();
    case 1:
      if (eof) ADVANCE(2);
      ADVANCE_MAP(
        '\n', 3,
        '\r', 48,
        ' ', 57,
        '#', 4,
        0xb7, 50,
        0x2022, 51,
        0x2500, 24,
        0x2502, 52,
        0x258c, 53,
        0x2716, 54,
        0x2610, 55,
        0x2611, 55,
      );
      if (('0' <= lookahead && lookahead <= '9')) ADVANCE(69);
      if (lookahead != 0) ADVANCE(70);
      END_STATE();
    case 2:
      ACCEPT_TOKEN(ts_builtin_sym_end);
      END_STATE();
    case 3:
      ACCEPT_TOKEN(sym__eol);
      END_STATE();
    case 4:
      ACCEPT_TOKEN(sym__title_text);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(4);
      END_STATE();
    case 5:
      ACCEPT_TOKEN(sym__user_header_text);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(5);
      END_STATE();
    case 6:
      ACCEPT_TOKEN(sym__assistant_header_text);
      if (lookahead == ' ') ADVANCE(8);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(21);
      END_STATE();
    case 7:
      ACCEPT_TOKEN(sym__assistant_header_text);
      if (lookahead == ' ') ADVANCE(6);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(21);
      END_STATE();
    case 8:
      ACCEPT_TOKEN(sym__assistant_header_text);
      if (lookahead == '(') ADVANCE(13);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(21);
      END_STATE();
    case 9:
      ACCEPT_TOKEN(sym__assistant_header_text);
      if (lookahead == ')') ADVANCE(21);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(21);
      END_STATE();
    case 10:
      ACCEPT_TOKEN(sym__assistant_header_text);
      if (lookahead == 'd') ADVANCE(9);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(21);
      END_STATE();
    case 11:
      ACCEPT_TOKEN(sym__assistant_header_text);
      if (lookahead == 'e') ADVANCE(17);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(21);
      END_STATE();
    case 12:
      ACCEPT_TOKEN(sym__assistant_header_text);
      if (lookahead == 'e') ADVANCE(10);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(21);
      END_STATE();
    case 13:
      ACCEPT_TOKEN(sym__assistant_header_text);
      if (lookahead == 'i') ADVANCE(14);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(21);
      END_STATE();
    case 14:
      ACCEPT_TOKEN(sym__assistant_header_text);
      if (lookahead == 'n') ADVANCE(18);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(21);
      END_STATE();
    case 15:
      ACCEPT_TOKEN(sym__assistant_header_text);
      if (lookahead == 'p') ADVANCE(19);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(21);
      END_STATE();
    case 16:
      ACCEPT_TOKEN(sym__assistant_header_text);
      if (lookahead == 'r') ADVANCE(20);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(21);
      END_STATE();
    case 17:
      ACCEPT_TOKEN(sym__assistant_header_text);
      if (lookahead == 'r') ADVANCE(16);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(21);
      END_STATE();
    case 18:
      ACCEPT_TOKEN(sym__assistant_header_text);
      if (lookahead == 't') ADVANCE(11);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(21);
      END_STATE();
    case 19:
      ACCEPT_TOKEN(sym__assistant_header_text);
      if (lookahead == 't') ADVANCE(12);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(21);
      END_STATE();
    case 20:
      ACCEPT_TOKEN(sym__assistant_header_text);
      if (lookahead == 'u') ADVANCE(15);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(21);
      END_STATE();
    case 21:
      ACCEPT_TOKEN(sym__assistant_header_text);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(21);
      END_STATE();
    case 22:
      ACCEPT_TOKEN(aux_sym_error_token1);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(22);
      END_STATE();
    case 23:
      ACCEPT_TOKEN(aux_sym_notice_token1);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(23);
      END_STATE();
    case 24:
      ACCEPT_TOKEN(aux_sym_rule_token1);
      if (lookahead == 0x2500) ADVANCE(24);
      END_STATE();
    case 25:
      ACCEPT_TOKEN(aux_sym_quote_token1);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(25);
      END_STATE();
    case 26:
      ACCEPT_TOKEN(aux_sym_task_token1);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(26);
      END_STATE();
    case 27:
      ACCEPT_TOKEN(aux_sym_bullet_token1);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(27);
      END_STATE();
    case 28:
      ACCEPT_TOKEN(aux_sym_ordered_token1);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(28);
      END_STATE();
    case 29:
      ACCEPT_TOKEN(aux_sym_tool_call_token1);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(29);
      END_STATE();
    case 30:
      ACCEPT_TOKEN(aux_sym_tool_output_token1);
      if (lookahead == ' ') ADVANCE(27);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(36);
      END_STATE();
    case 31:
      ACCEPT_TOKEN(aux_sym_tool_output_token1);
      if (lookahead == ' ') ADVANCE(25);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(36);
      END_STATE();
    case 32:
      ACCEPT_TOKEN(aux_sym_tool_output_token1);
      if (lookahead == ' ') ADVANCE(26);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(36);
      END_STATE();
    case 33:
      ACCEPT_TOKEN(aux_sym_tool_output_token1);
      if (lookahead == ' ') ADVANCE(28);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(36);
      END_STATE();
    case 34:
      ACCEPT_TOKEN(aux_sym_tool_output_token1);
      if (lookahead == ' ') ADVANCE(34);
      if (lookahead == 0x2022) ADVANCE(30);
      if (lookahead == 0x2502) ADVANCE(31);
      if (lookahead == 0x2610 ||
          lookahead == 0x2611) ADVANCE(32);
      if (('0' <= lookahead && lookahead <= '9')) ADVANCE(35);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(36);
      END_STATE();
    case 35:
      ACCEPT_TOKEN(aux_sym_tool_output_token1);
      if (lookahead == ')' ||
          lookahead == '.') ADVANCE(33);
      if (('0' <= lookahead && lookahead <= '9')) ADVANCE(35);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(36);
      END_STATE();
    case 36:
      ACCEPT_TOKEN(aux_sym_tool_output_token1);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(36);
      END_STATE();
    case 37:
      ACCEPT_TOKEN(aux_sym_code_token1);
      if (lookahead == ' ') ADVANCE(27);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(47);
      END_STATE();
    case 38:
      ACCEPT_TOKEN(aux_sym_code_token1);
      if (lookahead == ' ') ADVANCE(25);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(47);
      END_STATE();
    case 39:
      ACCEPT_TOKEN(aux_sym_code_token1);
      if (lookahead == ' ') ADVANCE(26);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(47);
      END_STATE();
    case 40:
      ACCEPT_TOKEN(aux_sym_code_token1);
      if (lookahead == ' ') ADVANCE(42);
      if (lookahead == 0x2022) ADVANCE(37);
      if (lookahead == 0x2502) ADVANCE(38);
      if (lookahead == 0x2699) ADVANCE(43);
      if (lookahead == 0x2610 ||
          lookahead == 0x2611) ADVANCE(39);
      if (('0' <= lookahead && lookahead <= '9')) ADVANCE(46);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(47);
      END_STATE();
    case 41:
      ACCEPT_TOKEN(aux_sym_code_token1);
      if (lookahead == ' ') ADVANCE(28);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(47);
      END_STATE();
    case 42:
      ACCEPT_TOKEN(aux_sym_code_token1);
      if (lookahead == ' ') ADVANCE(34);
      if (lookahead == 0x2022) ADVANCE(37);
      if (lookahead == 0x2502) ADVANCE(38);
      if (lookahead == 0x2610 ||
          lookahead == 0x2611) ADVANCE(39);
      if (('0' <= lookahead && lookahead <= '9')) ADVANCE(46);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(47);
      END_STATE();
    case 43:
      ACCEPT_TOKEN(aux_sym_code_token1);
      if (lookahead == ' ') ADVANCE(29);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(47);
      END_STATE();
    case 44:
      ACCEPT_TOKEN(aux_sym_code_token1);
      if (lookahead == ' ') ADVANCE(45);
      if (lookahead == 0x2022) ADVANCE(37);
      if (lookahead == 0x2502) ADVANCE(38);
      if (lookahead == 0x2699) ADVANCE(43);
      if (lookahead == 0x2610 ||
          lookahead == 0x2611) ADVANCE(39);
      if (('0' <= lookahead && lookahead <= '9')) ADVANCE(46);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(47);
      END_STATE();
    case 45:
      ACCEPT_TOKEN(aux_sym_code_token1);
      if (lookahead == ' ') ADVANCE(45);
      if (lookahead == 0x2022) ADVANCE(37);
      if (lookahead == 0x2502) ADVANCE(38);
      if (lookahead == 0x2610 ||
          lookahead == 0x2611) ADVANCE(39);
      if (('0' <= lookahead && lookahead <= '9')) ADVANCE(46);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(47);
      END_STATE();
    case 46:
      ACCEPT_TOKEN(aux_sym_code_token1);
      if (lookahead == ')' ||
          lookahead == '.') ADVANCE(41);
      if (('0' <= lookahead && lookahead <= '9')) ADVANCE(46);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(47);
      END_STATE();
    case 47:
      ACCEPT_TOKEN(aux_sym_code_token1);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(47);
      END_STATE();
    case 48:
      ACCEPT_TOKEN(sym__text);
      if (lookahead == '\n') ADVANCE(3);
      if (lookahead != 0) ADVANCE(70);
      END_STATE();
    case 49:
      ACCEPT_TOKEN(sym__text);
      if (lookahead == ' ') ADVANCE(40);
      if (lookahead == 0x2022) ADVANCE(51);
      if (lookahead == 0x2502) ADVANCE(52);
      if (lookahead == 0x2610 ||
          lookahead == 0x2611) ADVANCE(55);
      if (('0' <= lookahead && lookahead <= '9')) ADVANCE(69);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(70);
      END_STATE();
    case 50:
      ACCEPT_TOKEN(sym__text);
      if (lookahead == ' ') ADVANCE(23);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(70);
      END_STATE();
    case 51:
      ACCEPT_TOKEN(sym__text);
      if (lookahead == ' ') ADVANCE(27);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(70);
      END_STATE();
    case 52:
      ACCEPT_TOKEN(sym__text);
      if (lookahead == ' ') ADVANCE(25);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(70);
      END_STATE();
    case 53:
      ACCEPT_TOKEN(sym__text);
      if (lookahead == ' ') ADVANCE(58);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(70);
      END_STATE();
    case 54:
      ACCEPT_TOKEN(sym__text);
      if (lookahead == ' ') ADVANCE(22);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(70);
      END_STATE();
    case 55:
      ACCEPT_TOKEN(sym__text);
      if (lookahead == ' ') ADVANCE(26);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(70);
      END_STATE();
    case 56:
      ACCEPT_TOKEN(sym__text);
      if (lookahead == ' ') ADVANCE(28);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(70);
      END_STATE();
    case 57:
      ACCEPT_TOKEN(sym__text);
      if (lookahead == ' ') ADVANCE(44);
      if (lookahead == 0x2022) ADVANCE(51);
      if (lookahead == 0x2502) ADVANCE(52);
      if (lookahead == 0x2610 ||
          lookahead == 0x2611) ADVANCE(55);
      if (('0' <= lookahead && lookahead <= '9')) ADVANCE(69);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(70);
      END_STATE();
    case 58:
      ACCEPT_TOKEN(sym__text);
      if (lookahead == 'A') ADVANCE(65);
      if (lookahead == 'Y') ADVANCE(62);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(70);
      END_STATE();
    case 59:
      ACCEPT_TOKEN(sym__text);
      if (lookahead == 'a') ADVANCE(61);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(70);
      END_STATE();
    case 60:
      ACCEPT_TOKEN(sym__text);
      if (lookahead == 'i') ADVANCE(64);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(70);
      END_STATE();
    case 61:
      ACCEPT_TOKEN(sym__text);
      if (lookahead == 'n') ADVANCE(67);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(70);
      END_STATE();
    case 62:
      ACCEPT_TOKEN(sym__text);
      if (lookahead == 'o') ADVANCE(68);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(70);
      END_STATE();
    case 63:
      ACCEPT_TOKEN(sym__text);
      if (lookahead == 's') ADVANCE(60);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(70);
      END_STATE();
    case 64:
      ACCEPT_TOKEN(sym__text);
      if (lookahead == 's') ADVANCE(66);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(70);
      END_STATE();
    case 65:
      ACCEPT_TOKEN(sym__text);
      if (lookahead == 's') ADVANCE(63);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(70);
      END_STATE();
    case 66:
      ACCEPT_TOKEN(sym__text);
      if (lookahead == 't') ADVANCE(59);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(70);
      END_STATE();
    case 67:
      ACCEPT_TOKEN(sym__text);
      if (lookahead == 't') ADVANCE(7);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(70);
      END_STATE();
    case 68:
      ACCEPT_TOKEN(sym__text);
      if (lookahead == 'u') ADVANCE(5);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(70);
      END_STATE();
    case 69:
      ACCEPT_TOKEN(sym__text);
      if (lookahead == ')' ||
          lookahead == '.') ADVANCE(56);
      if (('0' <= lookahead && lookahead <= '9')) ADVANCE(69);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(70);
      END_STATE();
    case 70:
      ACCEPT_TOKEN(sym__text);
      if (lookahead != 0 &&
          lookahead != '\n') ADVANCE(70);
      END_STATE();
    default:
      return false;
  }
}

static const TSLexMode ts_lex_modes[STATE_COUNT] = {
  [0] = {.lex_state = 0},
  [1] = {.lex_state = 1},
  [2] = {.lex_state = 1},
  [3] = {.lex_state = 1},
  [4] = {.lex_state = 0},
  [5] = {.lex_state = 0},
  [6] = {.lex_state = 0},
  [7] = {.lex_state = 1},
  [8] = {.lex_state = 1},
  [9] = {.lex_state = 0},
  [10] = {.lex_state = 1},
  [11] = {.lex_state = 1},
  [12] = {.lex_state = 0},
  [13] = {.lex_state = 1},
  [14] = {.lex_state = 1},
  [15] = {.lex_state = 1},
  [16] = {.lex_state = 1},
  [17] = {.lex_state = 1},
  [18] = {.lex_state = 1},
  [19] = {.lex_state = 1},
  [20] = {.lex_state = 1},
  [21] = {.lex_state = 1},
  [22] = {.lex_state = 1},
  [23] = {.lex_state = 1},
  [24] = {.lex_state = 1},
  [25] = {.lex_state = 1},
  [26] = {.lex_state = 1},
  [27] = {.lex_state = 1},
  [28] = {.lex_state = 1},
  [29] = {.lex_state = 1},
  [30] = {.lex_state = 1},
  [31] = {.lex_state = 0},
  [32] = {.lex_state = 0},
  [33] = {.lex_state = 0},
  [34] = {.lex_state = 0},
  [35] = {.lex_state = 0},
  [36] = {.lex_state = 0},
  [37] = {.lex_state = 0},
  [38] = {.lex_state = 0},
  [39] = {.lex_state = 0},
  [40] = {.lex_state = 0},
  [41] = {.lex_state = 0},
  [42] = {.lex_state = 0},
  [43] = {.lex_state = 0},
  [44] = {.lex_state = 0},
  [45] = {.lex_state = 0},
  [46] = {.lex_state = 0},
  [47] = {.lex_state = 0},
};

static const uint16_t ts_parse_table[LARGE_STATE_COUNT][SYMBOL_COUNT] = {
  [0] = {
    [ts_builtin_sym_end] = ACTIONS(1),
    [sym__eol] = ACTIONS(1),
    [sym__title_text] = ACTIONS(1),
    [sym__user_header_text] = ACTIONS(1),
    [sym__assistant_header_text] = ACTIONS(1),
    [aux_sym_error_token1] = ACTIONS(1),
    [aux_sym_notice_token1] = ACTIONS(1),
    [aux_sym_rule_token1] = ACTIONS(1),
    [aux_sym_quote_token1] = ACTIONS(1),
    [aux_sym_task_token1] = ACTIONS(1),
    [aux_sym_bullet_token1] = ACTIONS(1),
    [aux_sym_ordered_token1] = ACTIONS(1),
    [aux_sym_tool_call_token1] = ACTIONS(1),
    [aux_sym_tool_output_token1] = ACTIONS(1),
    [aux_sym_code_token1] = ACTIONS(1),
    [sym__text] = ACTIONS(1),
  },
  [1] = {
    [sym_document] = STATE(42),
    [sym__line] = STATE(3),
    [sym_title] = STATE(3),
    [sym_user_header] = STATE(11),
    [sym_assistant_header] = STATE(10),
    [sym__user_message] = STATE(3),
    [sym__assistant_message] = STATE(3),
    [sym_error] = STATE(3),
    [sym_notice] = STATE(3),
    [sym_rule] = STATE(3),
    [sym_quote] = STATE(3),
    [sym_task] = STATE(3),
    [sym_bullet] = STATE(3),
    [sym_ordered] = STATE(3),
    [sym_tool_exchange] = STATE(3),
    [sym_tool_call] = STATE(4),
    [sym_code_block] = STATE(3),
    [sym_code] = STATE(7),
    [sym_blank] = STATE(3),
    [sym_text] = STATE(3),
    [aux_sym_document_repeat1] = STATE(3),
    [aux_sym_code_block_repeat1] = STATE(7),
    [ts_builtin_sym_end] = ACTIONS(3),
    [sym__eol] = ACTIONS(5),
    [sym__title_text] = ACTIONS(7),
    [sym__user_header_text] = ACTIONS(9),
    [sym__assistant_header_text] = ACTIONS(11),
    [aux_sym_error_token1] = ACTIONS(13),
    [aux_sym_notice_token1] = ACTIONS(15),
    [aux_sym_rule_token1] = ACTIONS(17),
    [aux_sym_quote_token1] = ACTIONS(19),
    [aux_sym_task_token1] = ACTIONS(21),
    [aux_sym_bullet_token1] = ACTIONS(23),
    [aux_sym_ordered_token1] = ACTIONS(25),
    [aux_sym_tool_call_token1] = ACTIONS(27),
    [aux_sym_code_token1] = ACTIONS(29),
    [sym__text] = ACTIONS(31),
  },
  [2] = {
    [sym__line] = STATE(2),
    [sym_title] = STATE(2),
    [sym_user_header] = STATE(11),
    [sym_assistant_header] = STATE(10),
    [sym__user_message] = STATE(2),
    [sym__assistant_message] = STATE(2),
    [sym_error] = STATE(2),
    [sym_notice] = STATE(2),
    [sym_rule] = STATE(2),
    [sym_quote] = STATE(2),
    [sym_task] = STATE(2),
    [sym_bullet] = STATE(2),
    [sym_ordered] = STATE(2),
    [sym_tool_exchange] = STATE(2),
    [sym_tool_call] = STATE(4),
    [sym_code_block] = STATE(2),
    [sym_code] = STATE(7),
    [sym_blank] = STATE(2),
    [sym_text] = STATE(2),
    [aux_sym_document_repeat1] = STATE(2),
    [aux_sym_code_block_repeat1] = STATE(7),
    [ts_builtin_sym_end] = ACTIONS(33),
    [sym__eol] = ACTIONS(35),
    [sym__title_text] = ACTIONS(38),
    [sym__user_header_text] = ACTIONS(41),
    [sym__assistant_header_text] = ACTIONS(44),
    [aux_sym_error_token1] = ACTIONS(47),
    [aux_sym_notice_token1] = ACTIONS(50),
    [aux_sym_rule_token1] = ACTIONS(53),
    [aux_sym_quote_token1] = ACTIONS(56),
    [aux_sym_task_token1] = ACTIONS(59),
    [aux_sym_bullet_token1] = ACTIONS(62),
    [aux_sym_ordered_token1] = ACTIONS(65),
    [aux_sym_tool_call_token1] = ACTIONS(68),
    [aux_sym_code_token1] = ACTIONS(71),
    [sym__text] = ACTIONS(74),
  },
  [3] = {
    [sym__line] = STATE(2),
    [sym_title] = STATE(2),
    [sym_user_header] = STATE(11),
    [sym_assistant_header] = STATE(10),
    [sym__user_message] = STATE(2),
    [sym__assistant_message] = STATE(2),
    [sym_error] = STATE(2),
    [sym_notice] = STATE(2),
    [sym_rule] = STATE(2),
    [sym_quote] = STATE(2),
    [sym_task] = STATE(2),
    [sym_bullet] = STATE(2),
    [sym_ordered] = STATE(2),
    [sym_tool_exchange] = STATE(2),
    [sym_tool_call] = STATE(4),
    [sym_code_block] = STATE(2),
    [sym_code] = STATE(7),
    [sym_blank] = STATE(2),
    [sym_text] = STATE(2),
    [aux_sym_document_repeat1] = STATE(2),
    [aux_sym_code_block_repeat1] = STATE(7),
    [ts_builtin_sym_end] = ACTIONS(77),
    [sym__eol] = ACTIONS(5),
    [sym__title_text] = ACTIONS(7),
    [sym__user_header_text] = ACTIONS(9),
    [sym__assistant_header_text] = ACTIONS(11),
    [aux_sym_error_token1] = ACTIONS(13),
    [aux_sym_notice_token1] = ACTIONS(15),
    [aux_sym_rule_token1] = ACTIONS(17),
    [aux_sym_quote_token1] = ACTIONS(19),
    [aux_sym_task_token1] = ACTIONS(21),
    [aux_sym_bullet_token1] = ACTIONS(23),
    [aux_sym_ordered_token1] = ACTIONS(25),
    [aux_sym_tool_call_token1] = ACTIONS(27),
    [aux_sym_code_token1] = ACTIONS(29),
    [sym__text] = ACTIONS(31),
  },
};

static const uint16_t ts_small_parse_table[] = {
  [0] = 5,
    ACTIONS(81), 1,
      aux_sym_tool_output_token1,
    STATE(27), 1,
      sym_tool_output_block,
    ACTIONS(83), 2,
      aux_sym_code_token1,
      sym__text,
    STATE(5), 2,
      sym_tool_output,
      aux_sym_tool_output_block_repeat1,
    ACTIONS(79), 13,
      ts_builtin_sym_end,
      sym__eol,
      sym__title_text,
      sym__user_header_text,
      sym__assistant_header_text,
      aux_sym_error_token1,
      aux_sym_notice_token1,
      aux_sym_rule_token1,
      aux_sym_quote_token1,
      aux_sym_task_token1,
      aux_sym_bullet_token1,
      aux_sym_ordered_token1,
      aux_sym_tool_call_token1,
  [30] = 4,
    ACTIONS(81), 1,
      aux_sym_tool_output_token1,
    ACTIONS(87), 2,
      aux_sym_code_token1,
      sym__text,
    STATE(6), 2,
      sym_tool_output,
      aux_sym_tool_output_block_repeat1,
    ACTIONS(85), 13,
      ts_builtin_sym_end,
      sym__eol,
      sym__title_text,
      sym__user_header_text,
      sym__assistant_header_text,
      aux_sym_error_token1,
      aux_sym_notice_token1,
      aux_sym_rule_token1,
      aux_sym_quote_token1,
      aux_sym_task_token1,
      aux_sym_bullet_token1,
      aux_sym_ordered_token1,
      aux_sym_tool_call_token1,
  [57] = 4,
    ACTIONS(91), 1,
      aux_sym_tool_output_token1,
    ACTIONS(94), 2,
      aux_sym_code_token1,
      sym__text,
    STATE(6), 2,
      sym_tool_output,
      aux_sym_tool_output_block_repeat1,
    ACTIONS(89), 13,
      ts_builtin_sym_end,
      sym__eol,
      sym__title_text,
      sym__user_header_text,
      sym__assistant_header_text,
      aux_sym_error_token1,
      aux_sym_notice_token1,
      aux_sym_rule_token1,
      aux_sym_quote_token1,
      aux_sym_task_token1,
      aux_sym_bullet_token1,
      aux_sym_ordered_token1,
      aux_sym_tool_call_token1,
  [84] = 4,
    ACTIONS(29), 1,
      aux_sym_code_token1,
    ACTIONS(98), 1,
      sym__text,
    STATE(8), 2,
      sym_code,
      aux_sym_code_block_repeat1,
    ACTIONS(96), 13,
      ts_builtin_sym_end,
      sym__eol,
      sym__title_text,
      sym__user_header_text,
      sym__assistant_header_text,
      aux_sym_error_token1,
      aux_sym_notice_token1,
      aux_sym_rule_token1,
      aux_sym_quote_token1,
      aux_sym_task_token1,
      aux_sym_bullet_token1,
      aux_sym_ordered_token1,
      aux_sym_tool_call_token1,
  [110] = 4,
    ACTIONS(102), 1,
      aux_sym_code_token1,
    ACTIONS(105), 1,
      sym__text,
    STATE(8), 2,
      sym_code,
      aux_sym_code_block_repeat1,
    ACTIONS(100), 13,
      ts_builtin_sym_end,
      sym__eol,
      sym__title_text,
      sym__user_header_text,
      sym__assistant_header_text,
      aux_sym_error_token1,
      aux_sym_notice_token1,
      aux_sym_rule_token1,
      aux_sym_quote_token1,
      aux_sym_task_token1,
      aux_sym_bullet_token1,
      aux_sym_ordered_token1,
      aux_sym_tool_call_token1,
  [136] = 2,
    ACTIONS(109), 3,
      aux_sym_tool_output_token1,
      aux_sym_code_token1,
      sym__text,
    ACTIONS(107), 13,
      ts_builtin_sym_end,
      sym__eol,
      sym__title_text,
      sym__user_header_text,
      sym__assistant_header_text,
      aux_sym_error_token1,
      aux_sym_notice_token1,
      aux_sym_rule_token1,
      aux_sym_quote_token1,
      aux_sym_task_token1,
      aux_sym_bullet_token1,
      aux_sym_ordered_token1,
      aux_sym_tool_call_token1,
  [157] = 4,
    ACTIONS(83), 1,
      aux_sym_code_token1,
    ACTIONS(111), 1,
      sym__text,
    STATE(26), 1,
      sym_assistant_message_header,
    ACTIONS(79), 13,
      ts_builtin_sym_end,
      sym__eol,
      sym__title_text,
      sym__user_header_text,
      sym__assistant_header_text,
      aux_sym_error_token1,
      aux_sym_notice_token1,
      aux_sym_rule_token1,
      aux_sym_quote_token1,
      aux_sym_task_token1,
      aux_sym_bullet_token1,
      aux_sym_ordered_token1,
      aux_sym_tool_call_token1,
  [182] = 4,
    ACTIONS(83), 1,
      aux_sym_code_token1,
    ACTIONS(113), 1,
      sym__text,
    STATE(25), 1,
      sym_user_prompt,
    ACTIONS(79), 13,
      ts_builtin_sym_end,
      sym__eol,
      sym__title_text,
      sym__user_header_text,
      sym__assistant_header_text,
      aux_sym_error_token1,
      aux_sym_notice_token1,
      aux_sym_rule_token1,
      aux_sym_quote_token1,
      aux_sym_task_token1,
      aux_sym_bullet_token1,
      aux_sym_ordered_token1,
      aux_sym_tool_call_token1,
  [207] = 2,
    ACTIONS(117), 3,
      aux_sym_tool_output_token1,
      aux_sym_code_token1,
      sym__text,
    ACTIONS(115), 13,
      ts_builtin_sym_end,
      sym__eol,
      sym__title_text,
      sym__user_header_text,
      sym__assistant_header_text,
      aux_sym_error_token1,
      aux_sym_notice_token1,
      aux_sym_rule_token1,
      aux_sym_quote_token1,
      aux_sym_task_token1,
      aux_sym_bullet_token1,
      aux_sym_ordered_token1,
      aux_sym_tool_call_token1,
  [228] = 2,
    ACTIONS(121), 2,
      aux_sym_code_token1,
      sym__text,
    ACTIONS(119), 13,
      ts_builtin_sym_end,
      sym__eol,
      sym__title_text,
      sym__user_header_text,
      sym__assistant_header_text,
      aux_sym_error_token1,
      aux_sym_notice_token1,
      aux_sym_rule_token1,
      aux_sym_quote_token1,
      aux_sym_task_token1,
      aux_sym_bullet_token1,
      aux_sym_ordered_token1,
      aux_sym_tool_call_token1,
  [248] = 2,
    ACTIONS(125), 2,
      aux_sym_code_token1,
      sym__text,
    ACTIONS(123), 13,
      ts_builtin_sym_end,
      sym__eol,
      sym__title_text,
      sym__user_header_text,
      sym__assistant_header_text,
      aux_sym_error_token1,
      aux_sym_notice_token1,
      aux_sym_rule_token1,
      aux_sym_quote_token1,
      aux_sym_task_token1,
      aux_sym_bullet_token1,
      aux_sym_ordered_token1,
      aux_sym_tool_call_token1,
  [268] = 2,
    ACTIONS(129), 2,
      aux_sym_code_token1,
      sym__text,
    ACTIONS(127), 13,
      ts_builtin_sym_end,
      sym__eol,
      sym__title_text,
      sym__user_header_text,
      sym__assistant_header_text,
      aux_sym_error_token1,
      aux_sym_notice_token1,
      aux_sym_rule_token1,
      aux_sym_quote_token1,
      aux_sym_task_token1,
      aux_sym_bullet_token1,
      aux_sym_ordered_token1,
      aux_sym_tool_call_token1,
  [288] = 2,
    ACTIONS(133), 2,
      aux_sym_code_token1,
      sym__text,
    ACTIONS(131), 13,
      ts_builtin_sym_end,
      sym__eol,
      sym__title_text,
      sym__user_header_text,
      sym__assistant_header_text,
      aux_sym_error_token1,
      aux_sym_notice_token1,
      aux_sym_rule_token1,
      aux_sym_quote_token1,
      aux_sym_task_token1,
      aux_sym_bullet_token1,
      aux_sym_ordered_token1,
      aux_sym_tool_call_token1,
  [308] = 2,
    ACTIONS(137), 2,
      aux_sym_code_token1,
      sym__text,
    ACTIONS(135), 13,
      ts_builtin_sym_end,
      sym__eol,
      sym__title_text,
      sym__user_header_text,
      sym__assistant_header_text,
      aux_sym_error_token1,
      aux_sym_notice_token1,
      aux_sym_rule_token1,
      aux_sym_quote_token1,
      aux_sym_task_token1,
      aux_sym_bullet_token1,
      aux_sym_ordered_token1,
      aux_sym_tool_call_token1,
  [328] = 2,
    ACTIONS(141), 2,
      aux_sym_code_token1,
      sym__text,
    ACTIONS(139), 13,
      ts_builtin_sym_end,
      sym__eol,
      sym__title_text,
      sym__user_header_text,
      sym__assistant_header_text,
      aux_sym_error_token1,
      aux_sym_notice_token1,
      aux_sym_rule_token1,
      aux_sym_quote_token1,
      aux_sym_task_token1,
      aux_sym_bullet_token1,
      aux_sym_ordered_token1,
      aux_sym_tool_call_token1,
  [348] = 2,
    ACTIONS(145), 2,
      aux_sym_code_token1,
      sym__text,
    ACTIONS(143), 13,
      ts_builtin_sym_end,
      sym__eol,
      sym__title_text,
      sym__user_header_text,
      sym__assistant_header_text,
      aux_sym_error_token1,
      aux_sym_notice_token1,
      aux_sym_rule_token1,
      aux_sym_quote_token1,
      aux_sym_task_token1,
      aux_sym_bullet_token1,
      aux_sym_ordered_token1,
      aux_sym_tool_call_token1,
  [368] = 2,
    ACTIONS(149), 2,
      aux_sym_code_token1,
      sym__text,
    ACTIONS(147), 13,
      ts_builtin_sym_end,
      sym__eol,
      sym__title_text,
      sym__user_header_text,
      sym__assistant_header_text,
      aux_sym_error_token1,
      aux_sym_notice_token1,
      aux_sym_rule_token1,
      aux_sym_quote_token1,
      aux_sym_task_token1,
      aux_sym_bullet_token1,
      aux_sym_ordered_token1,
      aux_sym_tool_call_token1,
  [388] = 2,
    ACTIONS(153), 2,
      aux_sym_code_token1,
      sym__text,
    ACTIONS(151), 13,
      ts_builtin_sym_end,
      sym__eol,
      sym__title_text,
      sym__user_header_text,
      sym__assistant_header_text,
      aux_sym_error_token1,
      aux_sym_notice_token1,
      aux_sym_rule_token1,
      aux_sym_quote_token1,
      aux_sym_task_token1,
      aux_sym_bullet_token1,
      aux_sym_ordered_token1,
      aux_sym_tool_call_token1,
  [408] = 2,
    ACTIONS(157), 2,
      aux_sym_code_token1,
      sym__text,
    ACTIONS(155), 13,
      ts_builtin_sym_end,
      sym__eol,
      sym__title_text,
      sym__user_header_text,
      sym__assistant_header_text,
      aux_sym_error_token1,
      aux_sym_notice_token1,
      aux_sym_rule_token1,
      aux_sym_quote_token1,
      aux_sym_task_token1,
      aux_sym_bullet_token1,
      aux_sym_ordered_token1,
      aux_sym_tool_call_token1,
  [428] = 2,
    ACTIONS(161), 2,
      aux_sym_code_token1,
      sym__text,
    ACTIONS(159), 13,
      ts_builtin_sym_end,
      sym__eol,
      sym__title_text,
      sym__user_header_text,
      sym__assistant_header_text,
      aux_sym_error_token1,
      aux_sym_notice_token1,
      aux_sym_rule_token1,
      aux_sym_quote_token1,
      aux_sym_task_token1,
      aux_sym_bullet_token1,
      aux_sym_ordered_token1,
      aux_sym_tool_call_token1,
  [448] = 2,
    ACTIONS(165), 2,
      aux_sym_code_token1,
      sym__text,
    ACTIONS(163), 13,
      ts_builtin_sym_end,
      sym__eol,
      sym__title_text,
      sym__user_header_text,
      sym__assistant_header_text,
      aux_sym_error_token1,
      aux_sym_notice_token1,
      aux_sym_rule_token1,
      aux_sym_quote_token1,
      aux_sym_task_token1,
      aux_sym_bullet_token1,
      aux_sym_ordered_token1,
      aux_sym_tool_call_token1,
  [468] = 2,
    ACTIONS(169), 2,
      aux_sym_code_token1,
      sym__text,
    ACTIONS(167), 13,
      ts_builtin_sym_end,
      sym__eol,
      sym__title_text,
      sym__user_header_text,
      sym__assistant_header_text,
      aux_sym_error_token1,
      aux_sym_notice_token1,
      aux_sym_rule_token1,
      aux_sym_quote_token1,
      aux_sym_task_token1,
      aux_sym_bullet_token1,
      aux_sym_ordered_token1,
      aux_sym_tool_call_token1,
  [488] = 2,
    ACTIONS(173), 2,
      aux_sym_code_token1,
      sym__text,
    ACTIONS(171), 13,
      ts_builtin_sym_end,
      sym__eol,
      sym__title_text,
      sym__user_header_text,
      sym__assistant_header_text,
      aux_sym_error_token1,
      aux_sym_notice_token1,
      aux_sym_rule_token1,
      aux_sym_quote_token1,
      aux_sym_task_token1,
      aux_sym_bullet_token1,
      aux_sym_ordered_token1,
      aux_sym_tool_call_token1,
  [508] = 2,
    ACTIONS(177), 2,
      aux_sym_code_token1,
      sym__text,
    ACTIONS(175), 13,
      ts_builtin_sym_end,
      sym__eol,
      sym__title_text,
      sym__user_header_text,
      sym__assistant_header_text,
      aux_sym_error_token1,
      aux_sym_notice_token1,
      aux_sym_rule_token1,
      aux_sym_quote_token1,
      aux_sym_task_token1,
      aux_sym_bullet_token1,
      aux_sym_ordered_token1,
      aux_sym_tool_call_token1,
  [528] = 2,
    ACTIONS(181), 2,
      aux_sym_code_token1,
      sym__text,
    ACTIONS(179), 13,
      ts_builtin_sym_end,
      sym__eol,
      sym__title_text,
      sym__user_header_text,
      sym__assistant_header_text,
      aux_sym_error_token1,
      aux_sym_notice_token1,
      aux_sym_rule_token1,
      aux_sym_quote_token1,
      aux_sym_task_token1,
      aux_sym_bullet_token1,
      aux_sym_ordered_token1,
      aux_sym_tool_call_token1,
  [548] = 2,
    ACTIONS(185), 2,
      aux_sym_code_token1,
      sym__text,
    ACTIONS(183), 13,
      ts_builtin_sym_end,
      sym__eol,
      sym__title_text,
      sym__user_header_text,
      sym__assistant_header_text,
      aux_sym_error_token1,
      aux_sym_notice_token1,
      aux_sym_rule_token1,
      aux_sym_quote_token1,
      aux_sym_task_token1,
      aux_sym_bullet_token1,
      aux_sym_ordered_token1,
      aux_sym_tool_call_token1,
  [568] = 2,
    ACTIONS(189), 2,
      aux_sym_code_token1,
      sym__text,
    ACTIONS(187), 13,
      ts_builtin_sym_end,
      sym__eol,
      sym__title_text,
      sym__user_header_text,
      sym__assistant_header_text,
      aux_sym_error_token1,
      aux_sym_notice_token1,
      aux_sym_rule_token1,
      aux_sym_quote_token1,
      aux_sym_task_token1,
      aux_sym_bullet_token1,
      aux_sym_ordered_token1,
      aux_sym_tool_call_token1,
  [588] = 1,
    ACTIONS(191), 1,
      sym__eol,
  [592] = 1,
    ACTIONS(193), 1,
      sym__eol,
  [596] = 1,
    ACTIONS(195), 1,
      sym__eol,
  [600] = 1,
    ACTIONS(197), 1,
      sym__eol,
  [604] = 1,
    ACTIONS(199), 1,
      sym__eol,
  [608] = 1,
    ACTIONS(201), 1,
      sym__eol,
  [612] = 1,
    ACTIONS(203), 1,
      sym__eol,
  [616] = 1,
    ACTIONS(205), 1,
      sym__eol,
  [620] = 1,
    ACTIONS(207), 1,
      sym__eol,
  [624] = 1,
    ACTIONS(209), 1,
      sym__eol,
  [628] = 1,
    ACTIONS(211), 1,
      sym__eol,
  [632] = 1,
    ACTIONS(213), 1,
      ts_builtin_sym_end,
  [636] = 1,
    ACTIONS(215), 1,
      sym__eol,
  [640] = 1,
    ACTIONS(217), 1,
      sym__eol,
  [644] = 1,
    ACTIONS(219), 1,
      sym__eol,
  [648] = 1,
    ACTIONS(221), 1,
      sym__eol,
  [652] = 1,
    ACTIONS(223), 1,
      sym__eol,
};

static const uint32_t ts_small_parse_table_map[] = {
  [SMALL_STATE(4)] = 0,
  [SMALL_STATE(5)] = 30,
  [SMALL_STATE(6)] = 57,
  [SMALL_STATE(7)] = 84,
  [SMALL_STATE(8)] = 110,
  [SMALL_STATE(9)] = 136,
  [SMALL_STATE(10)] = 157,
  [SMALL_STATE(11)] = 182,
  [SMALL_STATE(12)] = 207,
  [SMALL_STATE(13)] = 228,
  [SMALL_STATE(14)] = 248,
  [SMALL_STATE(15)] = 268,
  [SMALL_STATE(16)] = 288,
  [SMALL_STATE(17)] = 308,
  [SMALL_STATE(18)] = 328,
  [SMALL_STATE(19)] = 348,
  [SMALL_STATE(20)] = 368,
  [SMALL_STATE(21)] = 388,
  [SMALL_STATE(22)] = 408,
  [SMALL_STATE(23)] = 428,
  [SMALL_STATE(24)] = 448,
  [SMALL_STATE(25)] = 468,
  [SMALL_STATE(26)] = 488,
  [SMALL_STATE(27)] = 508,
  [SMALL_STATE(28)] = 528,
  [SMALL_STATE(29)] = 548,
  [SMALL_STATE(30)] = 568,
  [SMALL_STATE(31)] = 588,
  [SMALL_STATE(32)] = 592,
  [SMALL_STATE(33)] = 596,
  [SMALL_STATE(34)] = 600,
  [SMALL_STATE(35)] = 604,
  [SMALL_STATE(36)] = 608,
  [SMALL_STATE(37)] = 612,
  [SMALL_STATE(38)] = 616,
  [SMALL_STATE(39)] = 620,
  [SMALL_STATE(40)] = 624,
  [SMALL_STATE(41)] = 628,
  [SMALL_STATE(42)] = 632,
  [SMALL_STATE(43)] = 636,
  [SMALL_STATE(44)] = 640,
  [SMALL_STATE(45)] = 644,
  [SMALL_STATE(46)] = 648,
  [SMALL_STATE(47)] = 652,
};

static const TSParseActionEntry ts_parse_actions[] = {
  [0] = {.entry = {.count = 0, .reusable = false}},
  [1] = {.entry = {.count = 1, .reusable = false}}, RECOVER(),
  [3] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_document, 0, 0, 0),
  [5] = {.entry = {.count = 1, .reusable = true}}, SHIFT(28),
  [7] = {.entry = {.count = 1, .reusable = true}}, SHIFT(45),
  [9] = {.entry = {.count = 1, .reusable = true}}, SHIFT(44),
  [11] = {.entry = {.count = 1, .reusable = true}}, SHIFT(33),
  [13] = {.entry = {.count = 1, .reusable = true}}, SHIFT(34),
  [15] = {.entry = {.count = 1, .reusable = true}}, SHIFT(36),
  [17] = {.entry = {.count = 1, .reusable = true}}, SHIFT(38),
  [19] = {.entry = {.count = 1, .reusable = true}}, SHIFT(40),
  [21] = {.entry = {.count = 1, .reusable = true}}, SHIFT(32),
  [23] = {.entry = {.count = 1, .reusable = true}}, SHIFT(41),
  [25] = {.entry = {.count = 1, .reusable = true}}, SHIFT(43),
  [27] = {.entry = {.count = 1, .reusable = true}}, SHIFT(46),
  [29] = {.entry = {.count = 1, .reusable = false}}, SHIFT(47),
  [31] = {.entry = {.count = 1, .reusable = false}}, SHIFT(31),
  [33] = {.entry = {.count = 1, .reusable = true}}, REDUCE(aux_sym_document_repeat1, 2, 0, 0),
  [35] = {.entry = {.count = 2, .reusable = true}}, REDUCE(aux_sym_document_repeat1, 2, 0, 0), SHIFT_REPEAT(28),
  [38] = {.entry = {.count = 2, .reusable = true}}, REDUCE(aux_sym_document_repeat1, 2, 0, 0), SHIFT_REPEAT(45),
  [41] = {.entry = {.count = 2, .reusable = true}}, REDUCE(aux_sym_document_repeat1, 2, 0, 0), SHIFT_REPEAT(44),
  [44] = {.entry = {.count = 2, .reusable = true}}, REDUCE(aux_sym_document_repeat1, 2, 0, 0), SHIFT_REPEAT(33),
  [47] = {.entry = {.count = 2, .reusable = true}}, REDUCE(aux_sym_document_repeat1, 2, 0, 0), SHIFT_REPEAT(34),
  [50] = {.entry = {.count = 2, .reusable = true}}, REDUCE(aux_sym_document_repeat1, 2, 0, 0), SHIFT_REPEAT(36),
  [53] = {.entry = {.count = 2, .reusable = true}}, REDUCE(aux_sym_document_repeat1, 2, 0, 0), SHIFT_REPEAT(38),
  [56] = {.entry = {.count = 2, .reusable = true}}, REDUCE(aux_sym_document_repeat1, 2, 0, 0), SHIFT_REPEAT(40),
  [59] = {.entry = {.count = 2, .reusable = true}}, REDUCE(aux_sym_document_repeat1, 2, 0, 0), SHIFT_REPEAT(32),
  [62] = {.entry = {.count = 2, .reusable = true}}, REDUCE(aux_sym_document_repeat1, 2, 0, 0), SHIFT_REPEAT(41),
  [65] = {.entry = {.count = 2, .reusable = true}}, REDUCE(aux_sym_document_repeat1, 2, 0, 0), SHIFT_REPEAT(43),
  [68] = {.entry = {.count = 2, .reusable = true}}, REDUCE(aux_sym_document_repeat1, 2, 0, 0), SHIFT_REPEAT(46),
  [71] = {.entry = {.count = 2, .reusable = false}}, REDUCE(aux_sym_document_repeat1, 2, 0, 0), SHIFT_REPEAT(47),
  [74] = {.entry = {.count = 2, .reusable = false}}, REDUCE(aux_sym_document_repeat1, 2, 0, 0), SHIFT_REPEAT(31),
  [77] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_document, 1, 0, 0),
  [79] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym__line, 1, 0, 0),
  [81] = {.entry = {.count = 1, .reusable = false}}, SHIFT(39),
  [83] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym__line, 1, 0, 0),
  [85] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_tool_output_block, 1, 0, 0),
  [87] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_tool_output_block, 1, 0, 0),
  [89] = {.entry = {.count = 1, .reusable = true}}, REDUCE(aux_sym_tool_output_block_repeat1, 2, 0, 0),
  [91] = {.entry = {.count = 2, .reusable = false}}, REDUCE(aux_sym_tool_output_block_repeat1, 2, 0, 0), SHIFT_REPEAT(39),
  [94] = {.entry = {.count = 1, .reusable = false}}, REDUCE(aux_sym_tool_output_block_repeat1, 2, 0, 0),
  [96] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_code_block, 1, 0, 0),
  [98] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_code_block, 1, 0, 0),
  [100] = {.entry = {.count = 1, .reusable = true}}, REDUCE(aux_sym_code_block_repeat1, 2, 0, 0),
  [102] = {.entry = {.count = 2, .reusable = false}}, REDUCE(aux_sym_code_block_repeat1, 2, 0, 0), SHIFT_REPEAT(47),
  [105] = {.entry = {.count = 1, .reusable = false}}, REDUCE(aux_sym_code_block_repeat1, 2, 0, 0),
  [107] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_tool_call, 2, 0, 0),
  [109] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_tool_call, 2, 0, 0),
  [111] = {.entry = {.count = 1, .reusable = false}}, SHIFT(37),
  [113] = {.entry = {.count = 1, .reusable = false}}, SHIFT(35),
  [115] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_tool_output, 2, 0, 0),
  [117] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_tool_output, 2, 0, 0),
  [119] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_user_header, 2, 0, 0),
  [121] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_user_header, 2, 0, 0),
  [123] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_assistant_message_header, 2, 0, 0),
  [125] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_assistant_message_header, 2, 0, 0),
  [127] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_title, 2, 0, 0),
  [129] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_title, 2, 0, 0),
  [131] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_assistant_header, 2, 0, 0),
  [133] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_assistant_header, 2, 0, 0),
  [135] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_error, 2, 0, 0),
  [137] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_error, 2, 0, 0),
  [139] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_notice, 2, 0, 0),
  [141] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_notice, 2, 0, 0),
  [143] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_rule, 2, 0, 0),
  [145] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_rule, 2, 0, 0),
  [147] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_quote, 2, 0, 0),
  [149] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_quote, 2, 0, 0),
  [151] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_task, 2, 0, 0),
  [153] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_task, 2, 0, 0),
  [155] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_ordered, 2, 0, 0),
  [157] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_ordered, 2, 0, 0),
  [159] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_code, 2, 0, 0),
  [161] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_code, 2, 0, 0),
  [163] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_text, 2, 0, 0),
  [165] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_text, 2, 0, 0),
  [167] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym__user_message, 2, 0, 0),
  [169] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym__user_message, 2, 0, 0),
  [171] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym__assistant_message, 2, 0, 0),
  [173] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym__assistant_message, 2, 0, 0),
  [175] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_tool_exchange, 2, 0, 0),
  [177] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_tool_exchange, 2, 0, 0),
  [179] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_blank, 1, 0, 0),
  [181] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_blank, 1, 0, 0),
  [183] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_user_prompt, 2, 0, 0),
  [185] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_user_prompt, 2, 0, 0),
  [187] = {.entry = {.count = 1, .reusable = true}}, REDUCE(sym_bullet, 2, 0, 0),
  [189] = {.entry = {.count = 1, .reusable = false}}, REDUCE(sym_bullet, 2, 0, 0),
  [191] = {.entry = {.count = 1, .reusable = true}}, SHIFT(24),
  [193] = {.entry = {.count = 1, .reusable = true}}, SHIFT(21),
  [195] = {.entry = {.count = 1, .reusable = true}}, SHIFT(16),
  [197] = {.entry = {.count = 1, .reusable = true}}, SHIFT(17),
  [199] = {.entry = {.count = 1, .reusable = true}}, SHIFT(29),
  [201] = {.entry = {.count = 1, .reusable = true}}, SHIFT(18),
  [203] = {.entry = {.count = 1, .reusable = true}}, SHIFT(14),
  [205] = {.entry = {.count = 1, .reusable = true}}, SHIFT(19),
  [207] = {.entry = {.count = 1, .reusable = true}}, SHIFT(12),
  [209] = {.entry = {.count = 1, .reusable = true}}, SHIFT(20),
  [211] = {.entry = {.count = 1, .reusable = true}}, SHIFT(30),
  [213] = {.entry = {.count = 1, .reusable = true}},  ACCEPT_INPUT(),
  [215] = {.entry = {.count = 1, .reusable = true}}, SHIFT(22),
  [217] = {.entry = {.count = 1, .reusable = true}}, SHIFT(13),
  [219] = {.entry = {.count = 1, .reusable = true}}, SHIFT(15),
  [221] = {.entry = {.count = 1, .reusable = true}}, SHIFT(9),
  [223] = {.entry = {.count = 1, .reusable = true}}, SHIFT(23),
};

#ifdef __cplusplus
extern "C" {
#endif
#ifdef TREE_SITTER_HIDE_SYMBOLS
#define TS_PUBLIC
#elif defined(_WIN32)
#define TS_PUBLIC __declspec(dllexport)
#else
#define TS_PUBLIC __attribute__((visibility("default")))
#endif

TS_PUBLIC const TSLanguage *tree_sitter_dshchat(void) {
  static const TSLanguage language = {
    .version = LANGUAGE_VERSION,
    .symbol_count = SYMBOL_COUNT,
    .alias_count = ALIAS_COUNT,
    .token_count = TOKEN_COUNT,
    .external_token_count = EXTERNAL_TOKEN_COUNT,
    .state_count = STATE_COUNT,
    .large_state_count = LARGE_STATE_COUNT,
    .production_id_count = PRODUCTION_ID_COUNT,
    .field_count = FIELD_COUNT,
    .max_alias_sequence_length = MAX_ALIAS_SEQUENCE_LENGTH,
    .parse_table = &ts_parse_table[0][0],
    .small_parse_table = ts_small_parse_table,
    .small_parse_table_map = ts_small_parse_table_map,
    .parse_actions = ts_parse_actions,
    .symbol_names = ts_symbol_names,
    .symbol_metadata = ts_symbol_metadata,
    .public_symbol_map = ts_symbol_map,
    .alias_map = ts_non_terminal_alias_map,
    .alias_sequences = &ts_alias_sequences[0][0],
    .lex_modes = ts_lex_modes,
    .lex_fn = ts_lex,
    .primary_state_ids = ts_primary_state_ids,
  };
  return &language;
}
#ifdef __cplusplus
}
#endif
