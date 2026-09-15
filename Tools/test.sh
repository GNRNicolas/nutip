#!/bin/bash
# Black-box tests for the Nutip CLI: drives the built binary against a scratch
# folder and never touches the user's own nuts.
#
#   Tools/test.sh [path/to/Nutip]
#
# No -e: a failing assertion has to be collected and reported with the others,
# not end the run on the first one.
set -uo pipefail

cd "$(dirname "$0")/.."
PROJECT="$(pwd)"

# --- The binary under test --------------------------------------------------
# Never `nutip` from PATH: that one is the user's installation, pointed at the
# folder where their real nuts live.
BIN="${1:-$PROJECT/build/Nutip.app/Contents/MacOS/Nutip}"
if [ ! -x "$BIN" ]; then
  echo "building (no binary at $BIN)"
  ./build.sh >/dev/null || { echo "build failed"; exit 1; }
fi
[ -x "$BIN" ] || { echo "no binary at $BIN"; exit 1; }

# --- The scratch folder -----------------------------------------------------
# macOS `mktemp` ignores TMPDIR unless it is in the template, and a run that
# wrote outside a temporary directory would be writing into someone's nuts.
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/nutip-test.XXXXXX")" || exit 1
ROOT="$(cd "$ROOT" && pwd -P)"
case "$ROOT" in
  /private/var/folders/*|/var/folders/*|/private/tmp/*|/tmp/*) ;;
  *) rmdir "$ROOT" 2>/dev/null
     echo "refusing to run: scratch folder $ROOT is not under TMPDIR or /tmp"; exit 1 ;;
esac

# The search index lives outside the nuts folder, in Application Support, named
# after the folder's path. Cleaning the folder alone would leave one behind on
# every run, so the names are reproduced here the way Slug.make builds them.
INDEX_HOME="$HOME/Library/Application Support/Nutip"
DIRS=()
slug() {
  local s
  s=$(printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]' \
      | LC_ALL=C sed -e 's/[^a-z0-9][^a-z0-9]*/-/g' -e 's/^-//')
  s=${s:0:80}
  while [ "${s%-}" != "$s" ]; do s=${s%-}; done
  printf '%s' "$s"
}
cleanup() {
  local dir
  for dir in ${DIRS+"${DIRS[@]}"}; do
    rm -f "$INDEX_HOME/index-$(slug "$dir").sqlite" \
          "$INDEX_HOME/index-$(slug "$dir").sqlite-wal" \
          "$INDEX_HOME/index-$(slug "$dir").sqlite-shm"
  done
  rm -rf "$ROOT"
}
trap cleanup EXIT

MONTH="$(date +%Y-%m)"

# --- Harness ----------------------------------------------------------------
total=0; failed=0
ok()   { total=$((total+1)); printf '  ok    %s\n' "$1"; }
bad()  { total=$((total+1)); failed=$((failed+1)); printf '  FAIL  %s\n' "$1"
         [ $# -gt 1 ] && printf '        %s\n' "$2"; return 0; }
group() { printf '\n%s\n' "$1"; }

# Asserts a command succeeds. `check <name> <cmd...>`
check() { local name=$1; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }

OUT=""; ERR=""; ST=0
nut() { OUT=$("$BIN" "$@" 2>"$ROOT/.err"); ST=$?; ERR=$(cat "$ROOT/.err"); }

# A fresh nuts folder, so one section's files never explain another's result.
fresh() {
  D="$ROOT/$1"
  mkdir -p "$D"
  DIRS+=("$D")
  export NUTIP_DIR="$D"
}

contains()     { printf '%s' "$1" | grep -qF -- "$2"; }
not_contains() { ! printf '%s' "$1" | grep -qF -- "$2"; }
# Pipelines and `!` cannot be handed to `check`, which runs a single command.
has_line()     { grep -q -- "$1" "$2"; }
lacks_line()   { ! grep -q -- "$1" "$2"; }
first_line_has() { head -1 "$2" | grep -qF -- "$1"; }
# Nut files only: the generated INDEX.md sits in the same directory.
nutfiles() { find "$D/$MONTH" -maxdepth 1 -name '*.md' ! -name 'INDEX.md' 2>/dev/null; }
count_nutfiles() { nutfiles | wc -l | tr -d ' '; }

echo "nutip test suite"
echo "  binary  $BIN"
echo "  scratch $ROOT"

# --- 1. Lifecycle -----------------------------------------------------------
group "lifecycle"
fresh a

nut add "porcupine habitat notes" -t reading -w "for the talk"
check "add text exits 0" test "$ST" -eq 0
check "add text prints an absolute path that exists" test -f "$OUT"
TEXTNUT="$OUT"
front="$(sed -n '1,12p' "$TEXTNUT" 2>/dev/null)"
check "frontmatter has title"       contains "$front" 'title: "porcupine habitat notes"'
check "frontmatter has tags"        contains "$front" 'tags: [reading]'
check "frontmatter has why"         contains "$front" 'why: "for the talk"'
check "frontmatter has captured_at" grep -q '^captured_at: [0-9]\{4\}-' "$TEXTNUT"
check "frontmatter has source"      contains "$front" 'source: "CLI"'

nut add "https://example.com/zork" --title "Zork manual" -t reference -w "the classic"
check "add url exits 0" test "$ST" -eq 0
URLNUT="$OUT"
check "url nut keeps the url"       grep -q '^url: https://example.com/zork$' "$URLNUT"
check "url nut keeps the title"     grep -q '^title: "Zork manual"$' "$URLNUT"

nut recent 10
check "recent lists the text nut" contains "$OUT" "porcupine habitat notes"
check "recent lists the url nut"  contains "$OUT" "Zork manual"

# --- 2. Search --------------------------------------------------------------
group "search"

nut search porcupine
check "a word of the title finds the nut" contains "$OUT" "porcupine habitat notes"

nut search "#reference"
check "#tag keeps the tagged nut"    contains "$OUT" "Zork manual"
check "#tag drops the other one"     not_contains "$OUT" "porcupine"

nut search "@today"
check "@today finds today's nuts"    contains "$OUT" "Zork manual"
nut search "@links"
check "@links keeps the url nut"     contains "$OUT" "Zork manual"
check "@links drops the text nut"    not_contains "$OUT" "porcupine"
nut search "@text"
check "@text keeps the text nut"     contains "$OUT" "porcupine"
check "@text drops the url nut"      not_contains "$OUT" "Zork manual"

nut search "@nosuchfilter"
check "an unknown @filter is refused" test "$ST" -eq 1
check "and says where to look"        contains "$ERR" "nutip filters"

nut search zzqqxxnothing
check "an empty search does not crash"   test "$ST" -eq 0
check "an empty search says so"          contains "$OUT" "(no nuts)"
check "an empty search offers a way out" contains "$ERR" "Before concluding that nothing was saved"

nut search porcupine --json
check "--json emits an array" contains "$OUT" '"path"'
# JSONSerialization escapes the slashes; unescape before touching the disk.
jsonfile=$(printf '%s' "$OUT" | sed -n 's/.*"file" *: *"\(.*\)".*/\1/p' | head -1 | sed 's|\\/|/|g')
case "$jsonfile" in /*) ok "--json file is an absolute path" ;;
                    *) bad "--json file is an absolute path" "$jsonfile" ;; esac
check "--json file exists on disk"  test -f "$jsonfile"

# --- 3. Keywords ------------------------------------------------------------
group "keywords"
fresh b

body="Kubernetes scheduling is the topic of the day. The kubernetes scheduler and the \
kubernetes controller are described here, and the scheduler decides. Les pods sont des \
unites, et le scheduler pour les pods dans kubernetes. The scheduler and the pods and \
the kubernetes cluster, with pods and pods everywhere."
nut add "$body" -t reference --title "Kubernetes scheduling notes"
KW="$OUT"
kwline="$(grep '^keywords:' "$KW" 2>/dev/null)"
check "a repeated word becomes a keyword" contains "$kwline" "kubernetes"
check "so does the second one"            contains "$kwline" "scheduler"
for filler in the and les des pour; do
  check "the stop word '$filler' is not a keyword" not_contains "$kwline" " $filler,"
done

# A nut written by hand has no keywords: that is what `enrich` is for, and
# --dry-run has to leave the folder byte for byte as it found it.
cat > "$D/$MONTH/$MONTH-10-manual.md" <<'EOF'
---
title: "Manual nut about databases"
source: "hand"
captured_at: 2026-09-10T10:00:00+02:00
tags: [reference]
---

# Manual nut about databases

The database replication topic. Replication in a database is hard, and the database
replication lag matters. Database replication, replication, database. Les bases de
donnees et la replication dans une base de donnees avec replication.
EOF
nut reindex
before=$(find "$D" -type f -exec shasum {} \; | sort | shasum)
nut enrich --dry-run
check "enrich --dry-run exits 0"          test "$ST" -eq 0
check "enrich --dry-run says it is dry"   contains "$OUT" "--dry-run"
after=$(find "$D" -type f -exec shasum {} \; | sort | shasum)
check "enrich --dry-run changes nothing"  test "$before" = "$after"
check "the hand-written nut still has no keywords" \
      lacks_line '^keywords:' "$D/$MONTH/$MONTH-10-manual.md"

nut enrich
check "enrich writes keywords"  grep -q '^keywords:.*replication' "$D/$MONTH/$MONTH-10-manual.md"

# --- 4. Generated pages -----------------------------------------------------
group "generated pages"
fresh c

nut add "https://example.com/first" --title "First page" -t reading -w "one"
check "INDEX.md is written"           test -f "$D/INDEX.md"
check "the tag page is written"       test -f "$D/tags/reading.md"
check "the month page is written"     test -f "$D/$MONTH/INDEX.md"
check "INDEX.md mentions the nut"     grep -q "First page" "$D/INDEX.md"
check "the tag page mentions the nut" grep -q "First page" "$D/tags/reading.md"
check "the month page mentions it"    grep -q "First page" "$D/$MONTH/INDEX.md"
check "a generated page carries the marker" \
      first_line_has "generated by Nutip" "$D/INDEX.md"

# The marker is also the "may I overwrite this?" test. The day its wording
# changed, Nutip stopped recognising its own pages and silently froze them —
# no error anywhere. Counting the lines INDEX.md lists after a second nut is
# what catches that: a frozen INDEX.md still lists one.
nut add "https://example.com/second" --title "Second page" -t reading -w "two"
listed=$(grep -c '^- [0-9]\{4\}-' "$D/INDEX.md")
check "INDEX.md was rewritten for the second nut" test "$listed" -eq 2
check "the tag page was rewritten too"            grep -q "Second page" "$D/tags/reading.md"

# The other half of the same rule: a page the user took over has no marker, and
# must survive every save from then on.
printf 'my own notes, hands off\n' > "$D/tags/reading.md"
printf 'my own index\n' > "$D/INDEX.md"
mine=$(shasum "$D/tags/reading.md" "$D/INDEX.md")
nut add "https://example.com/third" --title "Third page" -t reading -w "three"
check "a user tag page without the marker is never overwritten" \
      test "$mine" = "$(shasum "$D/tags/reading.md" "$D/INDEX.md")"

# --- 5. Malformed files -----------------------------------------------------
group "malformed input"
fresh d

nut add "a sane nut to keep around" -t reading
sane="$OUT"

reindex_survives() { # <name>
  nut reindex
  if [ "$ST" -eq 0 ] && [ -f "$sane" ]; then ok "reindex survives $1"
  else bad "reindex survives $1" "exit $ST"; fi
}

printf -- '---\ntitle: "unterminated\nsource: "CLI"\n' > "$D/$MONTH/$MONTH-01-broken.md"
reindex_survives "a broken frontmatter"
printf -- 'no frontmatter at all, just prose\n' > "$D/$MONTH/$MONTH-02-plain.md"
reindex_survives "a file with no frontmatter"
printf -- '---\ntitle: "impossible date"\nsource: "CLI"\ncaptured_at: 2026-13-45T99:99:99\ntags: []\n---\n\nbody\n' \
  > "$D/$MONTH/$MONTH-03-baddate.md"
reindex_survives "an impossible date"

nut search sane
check "a good nut is still found next to broken ones" contains "$OUT" "a sane nut"

long=$(printf 'a%.0s' $(seq 1 300))
nut add "long title nut" --title "$long"
check "a 300-character title is accepted"  test "$ST" -eq 0
check "and lands inside the folder"        test -f "$OUT"
case "$OUT" in "$D"/*) ok "the long file name stays inside the folder" ;;
               *) bad "the long file name stays inside the folder" "$OUT" ;; esac

nut add "emoji title nut" --title "🎉🚀 fête"
check "an emoji title is accepted" test "$ST" -eq 0
check "and writes a readable file"  test -f "$OUT"

nut add "traversal nut" --title "../../escaped-by-nutip"
check "a ../ title is accepted" test "$ST" -eq 0
case "$OUT" in "$D"/"$MONTH"/*) ok "a ../ title cannot escape the folder" ;;
               *) bad "a ../ title cannot escape the folder" "$OUT" ;; esac
check "nothing was written next to the folder" \
      test -z "$(find "$ROOT" -maxdepth 1 -name '*escaped-by-nutip*')"
reindex_survives "the awkward titles"

# --- 6. The search index ----------------------------------------------------
group "search index"
fresh e

nut add "quantum widgets are lovely" -t ideas
DB="$INDEX_HOME/index-$(slug "$D").sqlite"
check "the index database is where its name says" test -f "$DB"

rm -f "$DB" "$DB-wal" "$DB-shm"
nut search quantum
check "a deleted index does not crash a search" test "$ST" -eq 0
check "and the nut is found again"              contains "$OUT" "quantum widgets"

head -c 4096 /dev/urandom > "$DB"
nut reindex
check "reindex recovers from a corrupted index" test "$ST" -eq 0
nut search quantum
check "and search works afterwards"             contains "$OUT" "quantum widgets"

# --- 7. Concurrency ---------------------------------------------------------
group "concurrency"
fresh f

for i in $(seq 1 10); do
  "$BIN" add "parallel nut number $i" -t reading >/dev/null 2>&1 &
done
wait
check "10 parallel adds write 10 files" test "$(count_nutfiles)" -eq 10
missing=""
for i in $(seq 1 10); do
  grep -rqF "parallel nut number $i" "$D/$MONTH" || missing="$missing $i"
done
check "no parallel add overwrote another" test -z "$missing"
nut reindex
check "reindex counts all 10" contains "$OUT" "reindexed 10 nuts"

# --- 8. Options that do not exist -------------------------------------------
group "option handling"
fresh g

before=$(count_nutfiles)
nut add "https://example.com/gamma" --bogus
check "an unknown flag is refused"        test "$ST" -eq 1
check "and says which one"                contains "$ERR" "unknown option --bogus"
check "and saves nothing"                 test "$(count_nutfiles)" -eq "$before"

# A flag left without its argument used to end up inside the saved URL: the nut
# looked right and its link was dead. It must be refused, not quietly dropped.
before=$(count_nutfiles)
nut add "https://example.com/delta" -w
check "a flag with no value is refused"   test "$ST" -ne 0
check "and says which flag"               contains "$ERR" "-w needs an argument"
check "and saves nothing either"          test "$(count_nutfiles)" -eq "$before"
saved=$(grep -rh '^url:' "$D/$MONTH" 2>/dev/null)
check "no flag text ever leaks into a saved url" not_contains "$saved" "-w"

# --- Summary ----------------------------------------------------------------
printf '\n%s\n' "----------------------------------------"
printf '%d tests, %d failed' "$total" "$failed"
printf '\n'
[ "$failed" -eq 0 ] || exit 1
