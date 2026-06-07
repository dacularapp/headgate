"""pipeline-demo — compile generated Mojo and run it in the sandbox. `pixi run pipeline-demo`.

Stands in for the model: two hardcoded "generated" programs are compiled and run
through Sandbox.compile_and_run over a real CSV:
  - BENIGN: counts data rows -> runs, computes over real data (ROW_COUNT=2).
  - MALICIOUS: tries to read $HOME/.zshrc -> the sandbox denies it (nonzero exit,
    no leak), proving generated code is contained.
"""

from std.ffi import external_call, c_int
from std.os import getenv
from sandbox import Sandbox, SandboxPolicy, RunResult


def _sh(var cmd: String) -> Int:
    return Int(external_call["system", c_int](cmd.as_c_string_slice()))


def _benign() -> String:
    # Counts non-empty data rows in the CSV (relative path resolves at the
    # binary's cwd = repo root, under the read-allowed data dir).
    var s = String("def main() raises:\n")
    s += "    var text: String\n"
    s += '    with open("demo/data/records.csv", "r") as f:\n'
    s += "        text = f.read()\n"
    s += '    var lines = text.split("\\n")\n'
    s += "    var count = 0\n"
    s += "    for i in range(1, len(lines)):\n"
    s += "        var ln = String(String(lines[i]).strip())\n"
    s += "        if ln.byte_length() > 0:\n"
    s += "            count += 1\n"
    s += '    print("ROW_COUNT=", count)\n'
    return s


def _malicious(home: String) -> String:
    # Attempts to read a file under $HOME — denied by the sandbox profile.
    var s = String("def main() raises:\n")
    s += "    var t: String\n"
    s += '    with open("' + home + '/.zshrc", "r") as f:\n'
    s += "        t = f.read()\n"
    s += '    print("LEAKED", t)\n'
    return s


def main() raises:
    _ = _sh("rm -rf demo && mkdir -p demo/data demo/scratch")
    _ = _sh("printf 'name,age\\nalice,30\\nbob,25\\n' > demo/data/records.csv")

    var policy = SandboxPolicy(String("demo/data"), String("demo/scratch"))
    var sb = Sandbox(policy^, String("sandbox/headgate.sb.template"))

    print("pipeline-demo: compile generated Mojo -> run in sandbox\n")
    var all_ok = True

    var r1 = sb.compile_and_run(_benign(), List[String]())
    var benign_ok = r1.exit_code == 0 and r1.output.find("ROW_COUNT=") != -1
    print("[" + ("PASS" if benign_ok else "FAIL") + "] benign generated code ran over real data:",
          String(r1.output.strip()))
    all_ok = all_ok and benign_ok

    var home = getenv("HOME", "/")
    var r2 = sb.compile_and_run(_malicious(home), List[String]())
    var contained = r2.exit_code != 0 and r2.output.find("LEAKED") == -1
    print("[" + ("PASS" if contained else "FAIL") + "] malicious generated code contained (exit",
          r2.exit_code, ", no leak)")
    all_ok = all_ok and contained

    _ = _sh("rm -rf demo")
    print()
    if all_ok:
        print("ALL CHECKS PASSED")
    else:
        print("CHECKS FAILED")
        raise Error("pipeline-demo: a check failed")
