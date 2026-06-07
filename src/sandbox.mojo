"""Sandbox — the CONTAINMENT half of headgate. Runs generated code in a box that
cannot phone home or escape its scope.

The boundary is PROVEN: see sandbox/headgate.sb.template + sandbox/spike.sh +
SPIKE.md (6/6 checks pass on macOS / Apple Silicon). This module renders that
template with canonical paths and runs the generated binary under sandbox-exec.

Per pi's thesis (PRIOR-ART.md): isolation lives OUTSIDE the agent, at the OS
level — not in-process. The harness owns confidentiality; this sandbox owns
containment; the two guarantees are kept separate.
"""


struct SandboxPolicy(Movable):
    var data_dir: String      # read-only mount of the task's private data
    var scratch_dir: String   # the only writable location (results land here)
    var network: String       # always "deny" for v1 — the primary control
    var cpu_seconds: Int
    var memory_mb: Int

    fn __init__(out self, owned data_dir: String, owned scratch_dir: String):
        self.data_dir = data_dir^
        self.scratch_dir = scratch_dir^
        self.network = String("deny")
        self.cpu_seconds = 30
        self.memory_mb = 1024


struct RunResult(Movable):
    var exit_code: Int
    var stdout: String   # captured locally — passes the EgressGuard before any reuse
    var stderr: String

    fn __init__(out self, exit_code: Int, owned stdout: String, owned stderr: String):
        self.exit_code = exit_code
        self.stdout = stdout^
        self.stderr = stderr^


fn _canonical(path: String) raises -> String:
    """Resolve symlinks to an absolute path. MANDATORY: Seatbelt matches the real
    path, and /tmp -> /private/tmp on macOS (SPIKE.md). TODO: realpath(3)."""
    return path  # TODO


fn _render_profile(template_path: String, policy: SandboxPolicy) raises -> String:
    """Substitute @DATA_DIR@ / @SCRATCH_DIR@ / @HOME@ in headgate.sb.template with
    canonical paths and write the rendered profile to the scratch dir. TODO."""
    return String("")  # TODO -> path to rendered .sb


struct Sandbox(Movable):
    var policy: SandboxPolicy
    var template_path: String   # sandbox/headgate.sb.template

    fn __init__(out self, owned policy: SandboxPolicy, owned template_path: String):
        self.policy = policy^
        self.template_path = template_path^

    fn run(self, binary: String, args: List[String]) raises -> RunResult:
        """Run `binary` under sandbox-exec with the rendered headgate profile:

            sandbox-exec -f <rendered.sb> <binary> <args...>

        network is denied, writes confined to scratch, reads exclude $HOME — the
        exact configuration sandbox/spike.sh verifies. TODO: posix_spawn via
        external_call, capture stdout/stderr, enforce cpu/mem limits."""
        var profile = _render_profile(self.template_path, self.policy)
        _ = profile
        _ = binary
        _ = args
        return RunResult(0, String(""), String(""))  # TODO
