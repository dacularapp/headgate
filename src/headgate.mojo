"""headgate — CLI entry point. Wires the layers and runs tasks over your data.

Layering (pi-shaped, PRIOR-ART.md):

    headgate.mojo        (this file — CLI + REPL)   server.mojo (HTTP, web)
              \\                                      /
               wiring.mojo   build_orchestrator(cfg, data_dir)
                                  |
    orchestrator.mojo    core loop: synthetic-debug -> real-run
        |        \\
    transport.mojo       schema.mojo / egress.mojo   (confidentiality policy)
        |
    sandbox.mojo + broker.mojo   (containment — PROVEN, see SPIKE.md)

Usage:
    headgate "<task>"               run one CSV task over your data, print the answer
    headgate                        interactive REPL: type a task, get an answer
    headgate vault "<question>" [dir]  answer a question about your private VAULT
                                    (CSV/PDF/Markdown) — the frontier model writes
                                    a Mojo program that uses the dacular vault
                                    tools; it runs locally over the real data and
                                    only the printed answer surfaces.

CSV data lives in `data_dir` (config: ~/.config/headgate/config.json, default
~/.config/headgate/data). On first run, if that folder has no .csv, headgate
asks where your data is — or seeds a small demo dataset.

The vault dir defaults to $DACULAR_VAULT, else $HEADGATE_DATA, else ~/dacular.
Index it first with `dacular index <dir>` (needs the embedding server live).
"""

from std.sys import argv
from std.os import getenv

from settings import load_config
from console import read_line
from wiring import build_orchestrator, build_vault_orchestrator, has_csv, seed_demo


def _resolve_data_dir(var data_dir: String) raises -> String:
    """Return a data dir that holds a .csv. If the configured one doesn't (first
    run), ask the user where their data is — or seed a demo on an empty answer."""
    if has_csv(data_dir):
        return data_dir^
    print("No data found at: " + data_dir)
    var r = read_line(
        "Path to a folder with your .csv (or press Enter to create a demo here): ")
    var chosen = r.text
    if chosen != "":
        if not has_csv(chosen):
            raise Error("no .csv found in: " + chosen)
        print(
            "Using " + chosen + '.  (Set "data_dir" in '
            "~/.config/headgate/config.json to remember it.)")
        return chosen^
    seed_demo(data_dir)
    print("Created a demo dataset at " + data_dir + "/records.csv")
    return data_dir^


def _vault_dir(var arg: String) raises -> String:
    """Resolve the vault dir for the `vault` subcommand: an explicit CLI arg wins,
    then $DACULAR_VAULT, then $HEADGATE_DATA, then ~/dacular (dacular's own
    default). Kept consistent with dacular/src/vault.mojo `_vault_dir()`."""
    if arg != "":
        return arg^
    var d = getenv("DACULAR_VAULT", "")
    if d != "":
        return d
    d = getenv("HEADGATE_DATA", "")
    if d != "":
        return d
    return getenv("HOME", ".") + "/dacular"


def _run_vault(cfg_question: String, var vault_dir: String) raises:
    """`headgate vault "<question>" [dir]` — the vault codegen loop."""
    var cfg = load_config()
    var dir = _vault_dir(vault_dir^)
    var orch = build_vault_orchestrator(cfg, dir)
    print(orch.run_vault_task(cfg_question, dir.copy()))


def main() raises:
    # `headgate vault "<question>" [dir]` — the private-vault codegen loop. Handled
    # first so it bypasses the CSV data-dir resolution (it has its own dir).
    var argv0 = argv()
    if len(argv0) > 1 and String(argv0[1]) == "vault":
        if len(argv0) < 3:
            print('usage: headgate vault "<question>" [vault_dir]')
            return
        var question = String(argv0[2])
        var vdir = String(argv0[3]) if len(argv0) >= 4 else String("")
        _run_vault(question, vdir^)
        return

    # Config: ~/.config/headgate/config.json (+ env overrides). See settings.mojo.
    var cfg = load_config()

    # Data dir from config (default ~/.config/headgate/data). Resolve — asking on
    # first run if there's no .csv — then wire the orchestrator over it.
    var data_dir = _resolve_data_dir(cfg.data_dir.copy())
    var orch = build_orchestrator(cfg, data_dir)

    # A task on the command line -> run it once. No task -> interactive REPL.
    var args = argv()
    if len(args) > 1:
        var task = String(args[1])
        for i in range(2, len(args)):
            task += " " + String(args[i])
        print(orch.run_task(task, data_dir.copy()))
        return

    print(
        "headgate writes code to answer questions ABOUT YOUR DATA — not a chatbot.")
    print("  e.g. 'how many rows', 'average amount by category'.")
    print("  Best with ANTHROPIC_API_KEY set (frontier model writes the code);")
    print("  without it, codegen falls back to the local model. Ctrl-D / 'exit' to quit.")
    while True:
        var r = read_line("\nheadgate> ")
        if r.eof:
            print("")
            break
        var task = r.text
        if task == "":
            continue
        if task == "exit" or task == "quit":
            break
        try:
            print(orch.run_task(task, data_dir.copy()))
        except e:
            print("error: " + String(e))
