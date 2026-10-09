#!/usr/bin/env bash
# Checks that the docs follow ASD-STE100 and the terminology table in
# CONTRIBUTING.md, as far as a script can. A reviewer checks the rest.
#
# Usage: test/lint-docs.sh [FILE...]
# With no FILE, checks the files in test/lint/ste-files.txt.
# Output: file:line: rule: text. Exit code 1 if there is a finding.
set -euo pipefail

cd "$(dirname "$0")/.."
WORDS=test/lint/ste-words.txt
MAX_WORDS=25
AWK=$(command -v gawk || command -v awk)

if [ $# -eq 0 ]; then
  mapfile -t files < <(grep -v '^#' test/lint/ste-files.txt | grep -v '^$')
  set -- "${files[@]}"
fi

rc=0
for f in "$@"; do
  [ -r "$f" ] || {
    echo "$f:0: missing: file does not exist"
    rc=1
    continue
  }
  while IFS=$'\t' read -r kind line text; do
    if [ "$kind" = LINK ]; then
      target=${text%%#*}
      [ -n "$target" ] || continue
      [ -e "$(dirname "$f")/$target" ] && continue
      echo "$f:$line: link: no file $target"
    else
      echo "$f:$line: $kind: $text"
    fi
    rc=1
  done < <(LC_ALL=C "$AWK" -v max="$MAX_WORDS" -v words="$WORDS" '
    BEGIN {
      FS = "\n"
      while ((getline w < words) > 0) {
        if (w ~ /^#/ || w == "") continue
        split(w, p, "|")
        nbad++; bad[nbad] = p[1]; fix[nbad] = p[2]
      }
    }
    function report(kind, ln, text) {
      if (length(text) > 70) text = substr(text, 1, 67) "..."
      printf "%s\t%d\t%s\n", kind, ln, text
    }
    function isword(c) { return c ~ /[a-z0-9]/ }
    # Words from the banned list, whole words only.
    function check_words(s, ln,   i, p, at, rest, pre, post) {
      for (i = 1; i <= nbad; i++) {
        rest = s; at = 0
        while ((p = index(rest, bad[i])) > 0) {
          pre = substr(rest, p - 1, 1); post = substr(rest, p + length(bad[i]), 1)
          if ((p == 1 || !isword(pre)) && !isword(post)) {
            report("word", ln, "\"" bad[i] "\": write " fix[i])
            break
          }
          rest = substr(rest, p + length(bad[i]))
        }
      }
    }
    # The end of a paragraph, list item or table cell.
    function flush(   i, n, start, sent) {
      n = 0; start = 0; sent = ""
      for (i = 1; i <= nw; i++) {
        if (n == 0) start = wl[i]
        n++; sent = sent (n > 1 ? " " : "") wt[i]
        if (wt[i] ~ /[.!?:]["'\'')*_]*$/ || i == nw) {
          if (n > max) report("long", start, n " words (max " max "): " sent)
          n = 0; sent = ""
        }
      }
      nw = 0
    }
    function add(s, ln,   k, t, n) {
      n = split(s, t, /[ \t]+/)
      for (k = 1; k <= n; k++) if (t[k] ~ /[A-Za-z0-9]/) { nw++; wt[nw] = t[k]; wl[nw] = ln }
    }
    {
      line = $0
      # YAML front matter, as in a custom agent file.
      if (NR == 1 && line == "---") { front = 1; next }
      if (front) { if (line == "---") front = 0; next }
      if (line ~ /^[ \t]*(```|~~~)/) { fence = !fence; flush(); next }
      if (fence) next
      # The terminology table lists the banned words, so it can turn the
      # word check off: <!-- lint-docs: words off --> ... words on -->.
      if (line ~ /<!-- lint-docs: words off -->/) nowords = 1
      if (line ~ /<!-- lint-docs: words on -->/) nowords = 0

      # Links in Markdown and in HTML.
      s = line
      while (match(s, /\]\([^)]+\)/)) {
        t = substr(s, RSTART + 2, RLENGTH - 3); sub(/[ \t].*/, "", t)
        if (t !~ /^(https?:|mailto:|#)/) printf "LINK\t%d\t%s\n", NR, t
        s = substr(s, RSTART + RLENGTH)
      }
      s = line
      while (match(s, /(href|src)="[^"]+"/)) {
        t = substr(s, RSTART, RLENGTH); sub(/^[a-z]+="/, "", t); sub(/"$/, "", t)
        if (t !~ /^(https?:|mailto:|#)/) printf "LINK\t%d\t%s\n", NR, t
        s = substr(s, RSTART + RLENGTH)
      }

      if (line ~ /^[ \t]*</) { flush(); next }
      if (line ~ /^[ \t]*$/ || line ~ /^#/) { flush(); next }

      # Text only: no code, link targets, URLs or Markdown marks.
      gsub(/`[^`]*`/, "code", line)
      gsub(/\]\([^)]*\)/, "", line)
      gsub(/https?:\/\/[^ )>]*/, "url", line)
      gsub(/[\[\]]/, "", line)
      gsub(/\342\200\231/, "'\''", line)
      sub(/^[ \t]*>[ \t]?/, "", line)

      low = tolower(line)
      gsub(/custom agents?/, "custom", low)
      gsub(/agents\.md/, "file", low)
      if (prevlow ~ /custom[ \t]*$/) sub(/^[ \t]*(- )?agents?/, "", low)
      prevlow = low
      if (!nowords) check_words(low, NR)
      if (low ~ /[a-z](n'\''t|'\''re|'\''ll|'\''ve|'\''d|'\''m)([^a-z]|$)/ \
        || low ~ /(^|[^a-z])(it|that|there|what|let|here|who)'\''s([^a-z]|$)/)
        report("contraction", NR, line)

      if (line ~ /^[ \t]*\|/) {
        flush()
        if (line ~ /^[ \t|:-]+$/) next
        n = split(line, cell, "|")
        for (c = 1; c <= n; c++) { add(cell[c], NR); flush() }
        next
      }
      if (line ~ /^[ \t]*([-*+]|[0-9]+\.)[ \t]/) flush()
      add(line, NR)
    }
    END { flush() }
  ' "$f")
done
exit $rc
