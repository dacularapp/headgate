#!/usr/bin/env bash
# headgate VAULT sandbox spike — prove the loopback-only network rule on macOS.
#
# Renders sandbox/headgate-vault.sb.template and verifies the ONE thing that
# distinguishes the vault run profile from the CSV one: outbound network is
# DENIED except to 127.0.0.1 / localhost. Everything else (read-scoping, scratch
# writes, $HOME deny) is identical to headgate.sb.template and already proven by
# spike.sh — this spike focuses on the loopback allowance.
#
# Seatbelt enforces at the syscall level, so stock tools stand in for the
# compiled Mojo binary the real runner wraps. We start a throwaway localhost HTTP
# listener so the loopback check tests a REAL successful connect (not just
# ECONNREFUSED), and use a non-routable TEST-NET address (192.0.2.1, RFC 5737)
# for the negative external check so it fails fast at the sandbox, never touching
# the real internet.
#
# Exit 0 iff all checks pass.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd -P)"
TEMPLATE="$HERE/headgate-vault.sb.template"
ROOT="${TMPDIR:-/tmp}/headgate_vault_spike.$$"

mkdir -p "$ROOT/data" "$ROOT/scratch" "$ROOT/index"
echo "PRIVATE-ROW: plate=8ABC123" > "$ROOT/data/records.csv"
echo "0	file_0	chunk text" > "$ROOT/index/chunks.tsv"

DATA="$(cd "$ROOT/data" && pwd -P)"
SCRATCH="$(cd "$ROOT/scratch" && pwd -P)"
INDEX="$(cd "$ROOT/index" && pwd -P)"
HOME_P="$(cd "$HOME" && pwd -P)"
RUNTIME_P="${CONDA_PREFIX:-/usr/lib}"

PROFILE="$ROOT/headgate-vault.sb"
sed -e "s#@DATA_DIR@#$DATA#g" \
    -e "s#@SCRATCH_DIR@#$SCRATCH#g" \
    -e "s#@HOME@#$HOME_P#g" \
    -e "s#@RUNTIME_PREFIX@#$RUNTIME_P#g" \
    -e "s#@INDEX_DIR@#$INDEX#g" \
    "$TEMPLATE" > "$PROFILE"

# Throwaway localhost TCP listener on a fixed port (so the loopback test is a
# REAL successful connect, not just ECONNREFUSED). Binds 127.0.0.1 only.
PORT=18799
python3 -c "
import socket
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', $PORT)); s.listen(8)
while True:
    c,_ = s.accept(); c.close()
" >/dev/null 2>&1 &
SRV=$!
sleep 1

# We test the connect() syscall directly with a tiny python client rather than
# curl: stock curl aborts during TLS/openssl.cnf init under the read-scoped
# profile (a curl artifact, not a network-rule effect), which would muddy the
# result. A raw socket connect is exactly what the Seatbelt network rule governs.
#   - 127.0.0.1:$PORT  -> connect SUCCEEDS  (loopback allowed)
#   - 192.0.2.1:80     -> connect BLOCKED   (RFC-5737 TEST-NET; never the wild)
CONNECT='
import socket, sys
host, port = sys.argv[1], int(sys.argv[2])
s = socket.socket(); s.settimeout(5)
try:
    s.connect((host, port)); print("connected"); sys.exit(0)
except Exception as e:
    print("FAILED:", e); sys.exit(1)
'
PY="$(command -v python3)"

run() { sandbox-exec -f "$PROFILE" "$@"; }
fails=0
check() { # name  expected(allow|deny)  cmd...
  local name="$1" expect="$2"; shift 2
  if "$@" >/dev/null 2>&1; then got=allow; else got=deny; fi
  if [ "$got" = "$expect" ]; then printf '  [PASS] %s\n' "$name"
  else printf '  [FAIL] %s (expected %s, got %s)\n' "$name" "$expect" "$got"; fails=$((fails+1)); fi
}

echo "headgate VAULT sandbox spike  (profile: $PROFILE)"
# THE loopback allowance: a real connect to 127.0.0.1 succeeds through the box.
check "loopback connect (127.0.0.1)"  allow run "$PY" -c "$CONNECT" 127.0.0.1 "$PORT"
# External egress is still denied by the sandbox (TEST-NET addr, never the wild).
check "external egress (TEST-NET)"    deny  run "$PY" -c "$CONNECT" 192.0.2.1 80
# Same containment as the CSV profile still holds.
check "in-scope vault read"           allow run /bin/cat "$DATA/records.csv"
check "index side-table read"         allow run /bin/cat "$INDEX/chunks.tsv"
check "home read (~/.zshrc)"          deny  run /bin/cat "$HOME_P/.zshrc"
check "out-of-scope write"            deny  run /usr/bin/touch "$DATA/evil.txt"
check "scratch write"                 allow run /usr/bin/touch "$SCRATCH/out.txt"

kill "$SRV" 2>/dev/null
rm -rf "$ROOT"
if [ "$fails" -eq 0 ]; then echo "ALL CHECKS PASSED"; exit 0
else echo "$fails CHECK(S) FAILED"; exit 1; fi
