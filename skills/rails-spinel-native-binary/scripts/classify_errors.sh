#!/bin/bash
# Summarise a `spin build` log: Spinel analysis refusals and C compiler errors, grouped and mapped to Ruby lines.
# Usage: classify_errors.sh <spin-build.log> <emitted-tree>
log="${1:?usage: classify_errors.sh <spin-build.log> <emitted-tree>}"; tree="${2:?}"
echo "== Spinel refusals (analysis stage), deduplicated by kind"
grep 'spinel:' "$log" | grep -v 'warning' | sed -E "s#^spinel: [^ ]*$tree/##; s/node [0-9]+ //" \
  | sed -E "s/^[^:]+:[0-9]+: //" | sed -E "s/undefined method '([^']+)'.*/undefined method \1/; s/unsupported call: \(CallNode \`([^\`]+)\`\).*/unsupported call \1/" \
  | sort | uniq -c | sort -rn | head -40
echo
echo "== C errors by kind (total: $(grep -c ' error: ' "$log"))"
grep ' error: ' "$log" | sed -E 's/.* error: //' | sed -E "s/‘[^’]*’/X/g" | sort | uniq -c | sort -rn | head -15
echo
echo "== C errors by Ruby file (those carrying a Ruby line; the rest sit in the generated split header)"
grep ' error: ' "$log" | grep -v spinel_split | sed -E "s#^$tree/##; s/:[0-9]+: error: .*//" | sort | uniq -c | sort -rn | head -20
echo "   in split files (no Ruby line): $(grep ' error: ' "$log" | grep -c spinel_split)"
echo
echo "== one sample per distinct Ruby site (kind | source line)"
grep ' error: ' "$log" | grep -v spinel_split | sed -E "s#^$tree/##" | awk -F: '!seen[$1":"$2]++' | head -40 \
  | while IFS=: read -r f l rest; do
      printf '%-50s %-38s %s\n' "$f:$l" "$(echo "$rest" | sed -E 's/^ error: //; s/‘[^’]*’/X/g' | cut -c1-38)" "$(sed -n "${l}p" "$tree/$f" 2>/dev/null | sed 's/^\s*//' | cut -c1-90)"
    done
