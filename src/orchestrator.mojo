"""Orchestrator — headgate's core loop (pi's `pi-agent-core` equivalent).

VAULT-ONLY. Wires the layers into the privacy flow (README.md):

  1. `veilens manifest` produces the ALIASED view (the only vault info the remote
     model sees — never a real name, value, or path).
  2. RemoteClient.codegen writes a `from vault import *` program from that (every
     outbound message passes the EgressGuard — confidentiality enforced here).
  3. compile it (with the veilens include paths), looping the fix on COMPILE
     errors only; the code is in terms of aliases, so there is no dealias step.
  4. run the program in the loopback Sandbox over REAL data; only the printed
     answer surfaces. search()/ask_local() reach 127.0.0.1 only.

See run_vault_task for the full confidentiality argument.
"""

from std.os import getenv, setenv

from budget import Budget
from transport import LocalClient, RemoteClient, ChatMessage, _codegen_system
from sandbox import Sandbox
from broker import CapabilityBroker
from vaultcfg import veilens_bin, vault_include_paths


def _session_append(text: String):
    """Append `text` to the session transcript at $VEILENS_SESSION_LOG (set by the
    CLI per `ask`), best-effort. Captures the full outside-model exchange — prompt
    + program — for after-the-fact inspection. No-op when the env var is unset."""
    var path = getenv("VEILENS_SESSION_LOG", "")
    if path == "":
        return
    try:
        with open(path, "a") as f:   # append mode (validated); creates if absent
            f.write(text)
    except:
        pass


struct Orchestrator(Movable):
    var local: LocalClient
    var remote: RemoteClient
    var sandbox: Sandbox
    var broker: CapabilityBroker
    var budget: Budget               # remote-API token budget; routes to local when depleted
    var use_local_summary: Bool      # have the local model summarize the result
    var max_fix_attempts: Int        # compile-feedback retries (compile errors only) before giving up

    def __init__(
        out self,
        var local: LocalClient,
        var remote: RemoteClient,
        var sandbox: Sandbox,
        var broker: CapabilityBroker,
        var budget: Budget,
        use_local_summary: Bool,
    ):
        self.local = local^
        self.remote = remote^
        self.sandbox = sandbox^
        self.broker = broker^
        self.budget = budget^
        self.use_local_summary = use_local_summary
        self.max_fix_attempts = 6

    def _codegen(mut self, messages: List[ChatMessage]) raises -> String:
        """Route code generation: the remote frontier model while budget remains,
        else the LOCAL model (trusted + free). Charges the budget by the remote
        token cost."""
        if self.budget.depleted():
            return self.local.codegen(messages)
        var g = self.remote.codegen(messages)
        self.budget.charge(g.tokens)
        return g.code.copy()

    def _fix(mut self, code: String, errors: String) raises -> String:
        """Route a fix the same way — remote while budget remains, else local."""
        if self.budget.depleted():
            return self.local.fix_code(code, errors)
        var g = self.remote.fix_code(code, errors)
        self.budget.charge(g.tokens)
        return g.code.copy()

    # ── vault pipeline (steps) ──────────────────────────────────────────────────
    # The full flow is run_vault_task; it's split into these public steps so the
    # streaming WS server (app/server) can emit status/debug between them and gate
    # step 4 on the user's approval. The CLI + the unary HTTP server call
    # run_vault_task and are unaffected.

    def vault_manifest(mut self, vault_dir: String) raises -> String:
        """Step 1 — the ALIASED, frontier-safe manifest. Shell out to the trusted
        `veilens manifest <vault_dir>` and capture its stdout. This is the ONLY
        vault info that reaches the remote model, aliases-only by construction."""
        print("• aliasing the vault manifest (the frontier-safe view)…")
        var dac = veilens_bin()
        var manifest_argv: List[String] = [dac, String("manifest"), vault_dir]
        var m = self.sandbox.capture(manifest_argv)
        if m.exit_code != 0:
            raise Error(
                "vault: `veilens manifest` failed (is veilens built at " + dac
                + "? try `pixi run build` in veilens). Output:\n" + m.output)
        return m.output.copy()

    def vault_codegen(mut self, question: String, manifest: String) raises -> String:
        """Step 2 — ask the model (budget-routed; EgressGuard-checked inside
        _codegen) for a `from vault import *` program from the question + the
        aliased manifest. The system prompt is resources/headgate-system.md."""
        print("• asking the outside model to write the program…")
        var user_msg = (
            String("Question: ") + question
            + "\n\nVault manifest (aliases only — you never see real content):\n"
            + manifest
            + "\n\nWrite the Mojo program (`from vault import *`) that answers it.")
        var msgs = List[ChatMessage]()
        msgs.append(ChatMessage(String("user"), user_msg))
        var code = self._codegen(msgs)
        _session_append(
            "QUESTION: " + question
            + "\n\n===== SYSTEM PROMPT =====\n" + _codegen_system()
            + "\n\n===== PROMPT TO THE OUTSIDE MODEL (user turn) =====\n" + user_msg
            + "\n\n===== OUTSIDE MODEL OUTPUT (program) =====\n" + code + "\n")
        return code

    def vault_build(mut self, code: String) raises:
        """Step 3 — compile with the vault include paths, looping the fix on
        COMPILE errors ONLY (the code is aliased, so compiler errors are safe to
        feed back; a RUNTIME error could carry real content and is never sent
        upstream). Leaves the compiled binary in scratch; raises if it never
        compiles."""
        print("• compiling the generated program…")
        var work = code.copy()
        var includes = vault_include_paths()
        var compiled = self.sandbox.compile(work, includes)
        var attempt = 0
        while compiled.exit_code != 0 and attempt < self.max_fix_attempts:
            work = self._fix(work, compiled.output)   # budget-routed; guarded; aliased
            compiled = self.sandbox.compile(work, includes)
            attempt += 1
        if compiled.exit_code != 0:
            raise Error(
                "vault: generated program did not compile after "
                + String(self.max_fix_attempts) + " fix attempt(s). Last error:\n"
                + compiled.output)

    def vault_run(mut self, vault_dir: String) raises -> String:
        """Step 4 — run the compiled binary in the LOOPBACK sandbox over the REAL
        data (network-denied EXCEPT 127.0.0.1, so search()/ask_local() reach the
        local models but the program cannot phone home). VEILENS_VAULT points the
        tools at the vault dir. Returns stdout (print_answer) — local; a runtime
        error surfaces here and is NEVER fed upstream."""
        print("• running it locally over your vault…")
        _ = setenv("VEILENS_VAULT", vault_dir, True)
        var bin = self.sandbox.scratch_bin()
        var out = self.sandbox.run(bin, List[String]()).output.copy()
        _session_append("\n===== RESULT (local — never sent upstream) =====\n" + out + "\n")
        return out

    def run_vault_task(mut self, question: String, vault_dir: String) raises -> String:
        """Answer a question about the private vault by writing ONE Mojo program
        that does `from vault import *` and calls the vault tools, compiling it
        with the veilens include paths, and running it in the loopback sandbox
        over the REAL data. Only the printed answer surfaces.

        This is the existing confidentiality model extended from "read one CSV" to
        "use the vault tools". The CONFIDENTIALITY INVARIANT, held end to end:

          - The ONLY vault information that reaches the remote (frontier) model is
            the ALIASED manifest (`file_0 [csv] 130 bytes  schema: col_0, col_1`)
            produced by `veilens manifest` — aliases/kinds/sizes/aliased columns,
            never a real name, value, or path (see veilens/src/manifest.mojo).
          - The question is the user's to send; the data is not. Every outbound
            message still passes the EgressGuard inside codegen()/fix_code()
            (fails closed) — a real value leaking into the manifest would trip it.
          - The generated program is written in terms of ALIASES (the tools TAKE
            aliases and resolve them locally), so there is NO dealias step — and
            nothing real is ever injected into the code (unlike the CSV path).
          - The program runs locally; search()/ask_local() hit ONLY 127.0.0.1
            (the loopback-only run profile, headgate-vault.sb.template, denies all
            other network); the answer is printed locally and returned here.

        So: aliases out, code back, run local over real data, answer local. The
        real content is touched only by the on-device tools, never the frontier.

        Auto-approved wrapper over the steps above; the WS server runs the steps
        directly to stream status/debug and gate the run on user approval."""
        var manifest = self.vault_manifest(vault_dir)
        var code = self.vault_codegen(question, manifest)
        self.vault_build(code)
        return self.vault_run(vault_dir)
