#!/usr/bin/env bash
# Build the bundled dshchat Tree-sitter parser.
#
# The generated src/parser.c is committed, so neither the tree-sitter CLI nor
# npm is needed here: only a C compiler. The output lands in
# <plugin>/parser/dshchat.so, which is on the plugin runtimepath, so
# `vim.treesitter.start` finds it without nvim-treesitter. With nvim-treesitter
# installed, `:TSInstall dshchat` builds the same source through the registered
# parser config instead.
#
# Regenerate the committed parser after editing grammar.js with:
#   (cd tree-sitter-dshchat && tree-sitter generate --abi 14 --no-bindings)
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
grammar="$root/tree-sitter-dshchat"
output="$root/parser/dshchat.so"

compiler="${CC:-cc}"
if ! command -v "$compiler" >/dev/null 2>&1; then
  echo "error: no C compiler ($compiler) found; install gcc or clang" >&2
  exit 1
fi

if [ ! -f "$grammar/src/parser.c" ]; then
  echo "error: $grammar/src/parser.c is missing; regenerate it from grammar.js" >&2
  exit 1
fi

mkdir -p "$root/parser"
"$compiler" -O2 -fPIC -shared -I"$grammar/src" "$grammar/src/parser.c" -o "$output"
echo "built $output"
