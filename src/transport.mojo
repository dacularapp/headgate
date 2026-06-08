"""Transport — HTTP to the two models over flare, with the EgressGuard on the remote path.

headgate's `pi-ai`-equivalent layer (PRIOR-ART.md): the one place network I/O
happens, so the one place egress policy is enforced. Now pure Mojo over flare's
HttpClient (no curl/python), parsing responses with flare's `Response.json()`.

Two clients, deliberately asymmetric:
  - LocalClient  -> the on-device model via `inference-server` (mojo-backend),
                    OpenAI /chat/completions over plain HTTP (127.0.0.1). No egress
                    guard: it never leaves the machine.
  - RemoteClient -> the frontier model (Anthropic Messages API, HTTPS). EVERY
                    message clears the EgressGuard before it touches the socket.

MOCK path: when ANTHROPIC_API_KEY is unset or HEADGATE_MOCK is set, codegen returns
a canned program so the pipeline runs offline.
"""

from std.os import getenv
from flare.http import HttpClient, Request
from egress import EgressGuard


# ── helpers ──────────────────────────────────────────────────────────────────

def _replace_all(s: String, old: String, new: String) raises -> String:
    var parts = s.split(old)
    var out = String("")
    for i in range(len(parts)):
        if i > 0:
            out += new
        out += String(parts[i])
    return out


def _json_escape(s: String) raises -> String:
    var o = _replace_all(s, String("\\"), String("\\\\"))
    o = _replace_all(o, String('"'), String('\\"'))
    o = _replace_all(o, String("\n"), String("\\n"))
    o = _replace_all(o, String("\r"), String("\\r"))
    o = _replace_all(o, String("\t"), String("\\t"))
    return o


def _strip_fences(var s: String) raises -> String:
    """If the model wrapped code in a ```...``` block, return the inside (minus
    the optional leading language tag). String has no slicing, so split + rejoin."""
    if s.find("```") == -1:
        return s^
    var parts = s.split("```")
    if len(parts) < 2:
        return s^
    var block = String(parts[1])
    if block.find("\n") == -1:
        return block^
    var lines = block.split("\n")
    var out = String("")
    for i in range(1, len(lines)):   # drop the language-tag line
        if i > 1:
            out += "\n"
        out += String(lines[i])
    return out^


def _mock_program() -> String:
    """Canned 'generated' program: count non-empty data rows in the CSV at the
    `__DATA_CSV__` placeholder (the orchestrator injects the real path)."""
    var s = String("def main() raises:\n")
    s += "    var text: String\n"
    s += '    with open("__DATA_CSV__", "r") as f:\n'
    s += "        text = f.read()\n"
    s += '    var lines = text.split("\\n")\n'
    s += "    var count = 0\n"
    s += "    for i in range(1, len(lines)):\n"
    s += "        var ln = String(String(lines[i]).strip())\n"
    s += "        if ln.byte_length() > 0:\n"
    s += "            count += 1\n"
    s += '    print("ROW_COUNT=", count)\n'
    return s


struct ChatMessage(Movable, Copyable):
    var role: String     # "system" | "user" | "assistant"
    var content: String

    def __init__(out self, var role: String, var content: String):
        self.role = role^
        self.content = content^


struct LocalClient(Movable):
    """Local model via inference-server, OpenAI /chat/completions over plain HTTP."""
    var base_url: String   # e.g. http://127.0.0.1:8000/v1

    def __init__(out self, var base_url: String):
        self.base_url = base_url^

    def chat(self, messages: List[ChatMessage]) raises -> String:
        """POST the messages and return the assistant content. Local only — no
        egress guard. Requires inference-server running."""
        var model = getenv("HEADGATE_LOCAL_MODEL", "local")
        var body = String('{"model":"') + model + '","messages":['
        for i in range(len(messages)):
            if i > 0:
                body += ","
            body += '{"role":"' + messages[i].role
            body += '","content":"' + _json_escape(messages[i].content) + '"}'
        body += "]}"

        var req = Request(
            method="POST",
            url=self.base_url + "/chat/completions",
            body=List[UInt8](body.as_bytes()),
        )
        req.headers.set("content-type", "application/json")
        var client = HttpClient()
        var resp = client.send(req)
        return resp.json()["choices"][0]["message"]["content"].string_value()


struct RemoteClient(Movable):
    """Frontier model (Anthropic Messages API, HTTPS). The guard gates the outbound
    path — enforced here, not left to callers, so it cannot be bypassed."""
    var base_url: String   # e.g. https://api.anthropic.com/v1
    var api_key: String
    var guard: EgressGuard

    def __init__(out self, var base_url: String, var api_key: String, var guard: EgressGuard):
        self.base_url = base_url^
        self.api_key = api_key^
        self.guard = guard^

    def codegen(self, messages: List[ChatMessage]) raises -> String:
        """Each message must clear the EgressGuard first (fails closed). Returns
        generated code (fences stripped). MOCK unless a real key is present."""
        var prompt = String("")
        for m in messages:
            var checked = self.guard.check(m.content)   # raises -> aborts send
            prompt += m.role + ": " + checked + "\n"

        var key = getenv("ANTHROPIC_API_KEY", "")
        if getenv("HEADGATE_MOCK", "") != "" or key == "":
            return _mock_program()
        return self._anthropic(prompt, key)

    def _anthropic(self, prompt: String, key: String) raises -> String:
        var sys = String(
            "You write a single self-contained Mojo program with"
            " `def main() raises:` that reads the CSV at __DATA_CSV__, computes the"
            " result, and prints it. Refer to columns by their aliases. Output only"
            " Mojo code."
        )
        var model = getenv("HEADGATE_MODEL", "claude-sonnet-4-6")
        var body = String('{"model":"') + model + '","max_tokens":2048,'
        body += '"system":"' + _json_escape(sys) + '",'
        body += '"messages":[{"role":"user","content":"' + _json_escape(prompt) + '"}]}'

        var req = Request(
            method="POST",
            url=self.base_url + "/messages",
            body=List[UInt8](body.as_bytes()),
        )
        req.headers.set("x-api-key", key)
        req.headers.set("anthropic-version", "2023-06-01")
        req.headers.set("content-type", "application/json")
        var client = HttpClient()
        var resp = client.send(req)
        return _strip_fences(resp.json()["content"][0]["text"].string_value())
