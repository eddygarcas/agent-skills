#!/bin/bash
# Syntax-check every Ruby file of an emitted spinel tree with CRuby's parser (Prism).
# Usage: check_parse.sh <emitted-tree>     -> lists unparseable files with the first error line; exit 1 if any.
tree="${1:?usage: check_parse.sh <emitted-tree>}"
bad=0
while IFS= read -r f; do
  if ! out=$(ruby -c "$f" 2>&1 >/dev/null); then
    bad=$((bad + 1))
    echo "== ${f#$tree/}"
    echo "$out" | grep -E '^\s*>' | head -2 | cut -c1-160
  fi
done < <(find "$tree/app" "$tree/runtime" "$tree/config" -name '*.rb' 2>/dev/null; ls "$tree"/main.rb "$tree"/boot.rb 2>/dev/null)
echo "unparseable files: $bad"
[ "$bad" -eq 0 ]
