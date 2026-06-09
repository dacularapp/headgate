"""wiring — build the headgate orchestrator + resolve the data dir.

Shared by the CLI (headgate.mojo) and the HTTP server (server.mojo) so both go
through one composition path. Kept out of headgate.mojo (which owns `main`) so
server.mojo can import it without pulling in a second `main`.
"""

from std.os import getenv, makedirs

from budget import Budget
from settings import Config
from egress import EgressGuard
from schema import SchemaSanitizer, fingerprints_from_csv, csv_path_for
from transport import LocalClient, RemoteClient
from sandbox import Sandbox, SandboxPolicy
from broker import CapabilityBroker
from orchestrator import Orchestrator


def has_csv(data_dir: String) -> Bool:
    """True if `data_dir` exists and holds a .csv (no crash if it's missing)."""
    try:
        _ = csv_path_for(data_dir)
        return True
    except:
        return False


def mkdirs(path: String):
    """`mkdir -p`; an already-existing path is fine (the error is swallowed)."""
    try:
        makedirs(path)
    except:
        pass  # already exists, or created concurrently


def write_file(path: String, content: String) raises:
    with open(path, "w") as f:
        f.write(content)


def seed_demo(data_dir: String) raises:
    """Create a tiny example CSV so a fresh install runs out of the box."""
    mkdirs(data_dir)
    var csv = String(
        "name,category,amount\n"
        "alice,books,12\n"
        "bob,food,7\n"
        "carol,books,20\n"
        "dave,food,5\n"
        "erin,toys,9\n"
    )
    write_file(data_dir + "/records.csv", csv)


def scratch_dir() -> String:
    """The sandbox scratch dir (always writable, created on use)."""
    return getenv("HOME", "") + "/.config/headgate/scratch"


def build_orchestrator(cfg: Config, data_dir: String) raises -> Orchestrator:
    """Wire the layers: egress guard (fingerprinted from the real data) gates the
    remote client; the sandbox contains generated code; the budget routes codegen
    to the local model when depleted. `data_dir` must already hold a .csv."""
    var scratch = scratch_dir()
    mkdirs(scratch)

    var guard = EgressGuard(fingerprints_from_csv(data_dir), List[String]())
    var local = LocalClient(cfg.local_url.copy(), cfg.local_model.copy())
    var remote = RemoteClient(
        cfg.remote_base_url.copy(), cfg.api_key.copy(), cfg.remote_model.copy(),
        cfg.mock, guard^,
    )
    var policy = SandboxPolicy(data_dir.copy(), scratch.copy())
    var sandbox = Sandbox(policy^, String("sandbox/headgate.sb.template"))

    var allowed = List[String]()
    allowed.append(String("read_table"))
    allowed.append(String("write_result"))
    allowed.append(String("log"))
    var broker = CapabilityBroker(allowed^)

    var budget = Budget(cfg.remote_token_budget)
    return Orchestrator(
        local^, remote^, SchemaSanitizer(), sandbox^, broker^, budget^,
        cfg.use_local_summary)
