"""schema-demo — exercise the real CSV SchemaSanitizer offline. `pixi run schema-demo`.

Writes a throwaway CSV, then prints the aliased schema (what the remote model
would see — no real names/values), synthetic sample rows, and a dealias round-trip
(aliases mapped back to real names, as happens before the sandbox runs the code).
"""

from std.ffi import external_call, c_int
from schema import SchemaSanitizer


def _sh(var cmd: String) -> Int:
    return Int(external_call["system", c_int](cmd.as_c_string_slice()))


def main() raises:
    _ = _sh("rm -rf demo && mkdir -p demo/data")
    _ = _sh("printf 'name,age,score\\nalice,30,9.5\\nbob,25,8.0\\ncarol,41,7.25\\n' > demo/data/people.csv")

    var s = SchemaSanitizer()
    var schema = s.sanitize(String("demo/data"))

    print("schema-demo (real CSV introspection)\n")
    print("aliased schema (remote-visible):", schema.aliased_json())
    print("synthetic samples (2 rows):     ", schema.synthetic_samples(2))

    var code = String('total = sum(col_1) + sum(col_2)  # over col_0 rows')
    print("generated code (aliased):       ", code)
    print("dealiased for local run:        ", schema.dealias_code(code))

    _ = _sh("rm -rf demo")
    print("\nexpected: col_0=string, col_1=int, col_2=float; dealias -> name/age/score")
