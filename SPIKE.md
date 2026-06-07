# Spike: code-runner sandbox (macOS / Seatbelt)

**Question:** can headgate's code-runner confine remote-generated code so it
cannot exfiltrate private data or escape its scope, using a mechanism available
today on the target platform (macOS, Apple Silicon)?

**Answer: yes** — via macOS `sandbox-exec` (Seatbelt). Profile lives in
`sandbox/headgate.sb.template`; the proof is `sandbox/spike.sh` (run it with
`pixi run spike`, or directly — it needs no Mojo toolchain).

## Result

```
headgate sandbox spike
  [PASS] in-scope data read        # the task's data dir IS readable
  [PASS] out-of-scope read         # a sibling secrets dir is NOT readable
  [PASS] home read (~/.zshrc)      # the real $HOME (~/.ssh, keys) is NOT readable
  [PASS] scratch write             # results can be written to the scratch dir
  [PASS] out-of-scope write        # writing anywhere else is blocked
  [PASS] network egress (curl)     # NO network — cannot phone home / exfiltrate
ALL CHECKS PASSED
```

The two guarantees from README.md, demonstrated:
- **Containment / no exfiltration** — `deny network*` blocks every socket, so
  generated code physically cannot send the private data anywhere.
- **Scope** — writes are confined to one scratch dir; reads exclude `$HOME`.

The sandboxed program's *language* is irrelevant here — Seatbelt enforces at the
syscall level — so the spike uses stock tools (`cat`, `touch`, `curl`) as a
stand-in for the compiled Mojo binary the real runner (`src/sandbox.mojo`) wraps.

## What made it work (and the dead ends)

1. **`deny default` aborts the process before it starts.** Even `/usr/bin/true`
   exits 134 (SIGABRT) — dyld can't bring up the runtime. Enumerating system
   read paths by hand (incl. the Darwin 25 dyld cache at
   `/System/Volumes/Preboot/Cryptexes/OS`) did **not** fix it.
2. **Importing the system baseline does.** `(import ".../bsd.sb")` sets up the
   mach/IPC bootstrap the process needs. After that, `bsd.sb` denies `exec`, so
   re-allow `process-exec*` / `process-fork` + executable reads of `/usr`, `/bin`,
   `/System`. Then layer the headgate denials: `network*`, `file-write*` (except
   scratch), and `file-read*` of `$HOME` (allowing only the data dir).
3. **Canonicalize paths.** `/tmp` → `/private/tmp`; Seatbelt matches the real
   path, so `subpath` rules must use symlink-resolved absolutes.

## Honest limitations (→ escalation path)

- **Read-scoping is blocklist-style here.** We deny `$HOME` and allow the data
  dir, but `bsd.sb` keeps broad system reads on, so world-readable paths *outside*
  `$HOME` remain reachable. Good enough for the careful-SaaS threat model (the
  primary control is network-deny, which is airtight); **not** a hard
  read-confinement guarantee.
- **Seatbelt is best-effort** (Cursor says the same of theirs). For a real
  guarantee against a non-careless adversary, escalate to the **microVM tier**
  with an egress allowlist (PRIOR-ART.md). This profile is the cheap, fast first
  line in front of that — not a replacement for it.
- **macOS-only.** Linux needs the Landlock+seccomp equivalent (tracked as future
  work; same `Sandbox` interface in `src/sandbox.mojo`).
