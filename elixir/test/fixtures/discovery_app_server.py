"""Deterministic app-server peer: attempts a mutation and validates host refusal."""
import json
import sys
from pathlib import Path

fixture, source = sys.argv[1:3]
mode = sys.argv[3] if len(sys.argv) > 3 else "ready"
log = sys.argv[4] if len(sys.argv) > 4 else None
model = None
def send(value):
    print(json.dumps(value), flush=True)

def receive():
    return json.loads(sys.stdin.readline())

while True:
    line = sys.stdin.readline()
    if not line:
        break
    message = json.loads(line)
    method, ident = message.get("method"), message.get("id")
    if method == "initialize":
        send({"id": ident, "result": {"userAgent": "discovery-fixture"}})
    elif method == "config/read":
        send({"id": ident, "result": {"config": {"mcp_servers": {"dangerous": {"enabled": True}}}}})
    elif method == "thread/start":
        params = message["params"]
        model = params["model"]
        assert params["sandbox"] == "read-only"
        assert params["approvalPolicy"] == "never"
        assert params["dynamicTools"] == []
        for key in ["features.multi_agent", "features.apps", "features.plugins", "mcp_servers.dangerous.enabled"]:
            assert params["config"][key] is False
        send({"id": ident, "result": {"thread": {"id": "discovery-thread"}, "model": params["model"],
              "approvalPolicy": "never", "sandbox": {"type": "readOnly", "networkAccess": False}}})
    elif method == "turn/start":
        assert message["params"]["sandboxPolicy"] == {"type": "readOnly"}
        send({"id": ident, "result": {"turn": {"id": "discovery-turn"}}})
        if log:
            with open(log, "a", encoding="utf-8") as stream:
                stream.write(json.dumps({"model": model, "input": message["params"]["input"][0]["text"]}) + "\n")
        if mode == "rate-limit" and model == "xai/grok-4.6":
            send({"method": "item/completed", "params": {"item": {"type": "agentMessage", "phase": "final_answer", "text": "partial primary output"}}})
            send({"method": "turn/completed", "params": {"turn": {"status": "failed", "error": {"codexErrorInfo": "rateLimitExceeded"}}}})
            continue
        send({"id": 91, "method": "item/tool/call", "params": {"tool": "linear_graphql",
              "arguments": {"query": "mutation { forbidden }"}}})
        denied = receive()
        assert denied["id"] == 91
        assert denied["result"]["success"] is False
        output = Path(fixture).read_text().replace("C:/repo/symphony", source)
        send({"method": "item/completed", "params": {"item": {"type": "agentMessage", "phase": "final_answer", "text": output}}})
        send({"method": "turn/completed", "params": {"turn": {"id": "discovery-turn", "status": "completed"}}})
