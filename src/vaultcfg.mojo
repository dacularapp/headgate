"""vaultcfg — resolve the veilens vault paths the orchestrator's vault path needs.

The vault path compiles a frontier-written program that does `from vault import *`
and runs it. To do that headgate needs to know, all relative to a configured
veilens checkout (or the sibling layout):

  - the veilens `build/veilens` binary    (to print the aliased manifest)
  - the `-I` include set for `mojo build` (veilens/src + flare/json/lancedb/
    pdftotext/zlib so the generated program + its transitive deps resolve)
  - the LanceDB index dir                 (~/.config/veilens — read-allowed in
    the vault run sandbox)

Resolution (highest precedence first):
  HEADGATE_VAULT_SRC  — explicit colon-separated -I list (overrides everything)
  HEADGATE_VEILENS    — path to the veilens checkout; deps assumed sibling to it
  default             — the sibling layout: <headgate>/../veilens etc.

`_veilens_dir()` defaults to ../veilens relative to the headgate cwd. Everything
else (flare/json/…) is a sibling of veilens, matching veilens/pixi.toml's own
`-I ../flare -I ../json -I ../lancedb.mojo/src -I ../pdftotext.mojo/src
-I ../zlib.mojo/src`.
"""

from std.os import getenv


def _split_colon(s: String) raises -> List[String]:
    var out = List[String]()
    var parts = s.split(":")
    for i in range(len(parts)):
        var p = String(String(parts[i]).strip())
        if p.byte_length() > 0:
            out.append(p^)
    return out^


def veilens_dir() raises -> String:
    """The veilens checkout. HEADGATE_VEILENS overrides; else ../veilens (sibling
    of the headgate cwd — how the repos are laid out)."""
    var d = getenv("HEADGATE_VEILENS", "")
    if d != "":
        return d
    return String("../veilens")


def veilens_bin() raises -> String:
    """The compiled veilens CLI (used to print the aliased manifest)."""
    return veilens_dir() + "/build/veilens"


def vault_include_paths() raises -> List[String]:
    """The `-I` dirs for compiling a `from vault import *` program. Mirrors
    veilens/pixi.toml's build line: veilens/src + flare + json + lancedb.mojo/src
    + pdftotext.mojo/src + zlib.mojo/src.

    HEADGATE_VAULT_SRC (colon-separated) overrides the whole set. Otherwise the
    deps are resolved as SIBLINGS of the veilens dir (so a moved veilens keeps
    its deps adjacent)."""
    var override = getenv("HEADGATE_VAULT_SRC", "")
    if override != "":
        return _split_colon(override)

    var dac = veilens_dir()
    # The sibling root: veilens's parent dir. If veilens is "../veilens", the
    # parent is "..". We keep it relative so it resolves from the headgate cwd,
    # matching veilens/pixi.toml's own relative `-I ../flare` style.
    var sib = dac + "/.."
    var out = List[String]()
    out.append(dac + "/src")
    out.append(sib + "/flare")
    out.append(sib + "/json")
    out.append(sib + "/lancedb.mojo/src")
    out.append(sib + "/pdftotext.mojo/src")
    out.append(sib + "/zlib.mojo/src")
    out.append(sib + "/csv.mojo/src")
    return out^


def vault_dir() raises -> String:
    """Resolve the vault dir for the SERVER's vault mode: HEADGATE_VAULT_DIR wins,
    then $VEILENS_VAULT, then $HEADGATE_DATA, then ~/veilens (veilens's own
    default). Mirrors headgate.mojo `_vault_dir()` (with no CLI arg) + veilens/src/
    vault.mojo `_vault_dir()`."""
    var d = getenv("HEADGATE_VAULT_DIR", "")
    if d != "":
        return d
    d = getenv("VEILENS_VAULT", "")
    if d != "":
        return d
    d = getenv("HEADGATE_DATA", "")
    if d != "":
        return d
    return getenv("HOME", ".") + "/veilens"


def vault_index_dir() raises -> String:
    """The veilens LanceDB index dir — read-allowed in the vault run sandbox so
    search() can reach the vector store + chunks.tsv side-table. Mirrors
    veilens/src/index.mojo `_config_dir()`."""
    return getenv("HOME", ".") + "/.config/veilens"
