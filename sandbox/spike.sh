#!/usr/bin/env bash
# headgate sandbox spike — prove the code-runner containment boundary on macOS.
#
# Renders sandbox/headgate.sb.template against a throwaway demo layout and runs
# six checks. The generated code's *language* is irrelevant to this boundary
# (Seatbelt enforces at the syscall level), so we use stock tools (/bin/cat,
# touch, curl) as a stand-in for the compiled Mojo binary the real runner wraps.
#
# Exit 0 iff all six pass. See SPIKE.md for the meaning of each check.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd -P)"
TEMPLATE="$HERE/headgate.sb.template"
ROOT="${TMPDIR:-/tmp}/headgate_spike.$$"

# Demo layout: in-scope private data, out-of-scope secrets, scratch.
mkdir -p "$ROOT/data" "$ROOT/scratch" "$ROOT/private"
echo "PRIVATE-ROW: ssn=123-45-6789" > "$ROOT/data/records.csv"
echo "OUT-OF-SCOPE SECRET" > "$ROOT/private/keys.txt"

# Canonical (symlink-resolved) paths — Seatbelt matches the real path, and on
# macOS /tmp -> /private/tmp, so this resolution is mandatory.
DATA="$(cd "$ROOT/data" && pwd -P)"
SCRATCH="$(cd "$ROOT/scratch" && pwd -P)"
PRIVATE="$(cd "$ROOT/private" && pwd -P)"
HOME_P="$(cd "$HOME" && pwd -P)"

PROFILE="$ROOT/headgate.sb"
# @RUNTIME_PREFIX@ is the language runtime (pixi env); irrelevant to this shell
# spike's stock-tool tests, so point it at a harmless existing path.
RUNTIME_P="${CONDA_PREFIX:-/usr/lib}"
sed -e "s#@DATA_DIR@#$DATA#g" \
    -e "s#@SCRATCH_DIR@#$SCRATCH#g" \
    -e "s#@HOME@#$HOME_P#g" \
    -e "s#@RUNTIME_PREFIX@#$RUNTIME_P#g" \
    "$TEMPLATE" > "$PROFILE"

run() { sandbox-exec -f "$PROFILE" "$@"; }
fails=0
check() { # name  expected(allow|deny)  cmd...
  local name="$1" expect="$2"; shift 2
  if "$@" >/dev/null 2>&1; then got=allow; else got=deny; fi
  if [ "$got" = "$expect" ]; then printf '  [PASS] %s\n' "$name"
  else printf '  [FAIL] %s (expected %s, got %s)\n' "$name" "$expect" "$got"; fails=$((fails+1)); fi
}

echo "headgate sandbox spike  (profile: $PROFILE)"
check "in-scope data read"        allow run /bin/cat       "$DATA/records.csv"
check "out-of-scope read"         deny  run /bin/cat       "$PRIVATE/keys.txt"
check "home read (~/.zshrc)"      deny  run /bin/cat       "$HOME_P/.zshrc"
check "scratch write"             allow run /usr/bin/touch "$SCRATCH/out.txt"
check "out-of-scope write"        deny  run /usr/bin/touch "$DATA/evil.txt"
check "network egress (curl)"     deny  run /usr/bin/curl -s --max-time 5 http://example.com

rm -rf "$ROOT"
if [ "$fails" -eq 0 ]; then echo "ALL CHECKS PASSED"; exit 0
else echo "$fails CHECK(S) FAILED"; exit 1; fi
