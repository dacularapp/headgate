"""flare-probe — prove flare's HttpClient is usable from headgate's env.

A minimal GET against a local server. If this compiles (flare source resolves via
-I ../flare, transitively pulling -I ../json) and runs (flare's FFI shims load from
this env's $CONDA_PREFIX/lib, built by the `flare-ffi` task), then the transport
layer can be wired to flare. Run: `pixi run flare-probe` with a server on :8799.
"""

from flare.http import HttpClient


def main() raises:
    var client = HttpClient()
    try:
        var resp = client.get("http://127.0.0.1:8799/")
        print("flare-probe: status =", resp.status)
        print("flare-probe: body   =", resp.text())
        print("FLARE HTTP OK")
    except e:
        print("flare-probe: request failed:", String(e))
