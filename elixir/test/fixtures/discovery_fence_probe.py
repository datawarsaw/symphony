"""Fence probe: witnesses the Discovery launch marker from inside the worker.

The harness points the Discovery codex command at this wrapper. As the first
instructions of the worker process, before any app-server protocol activity,
it reads the issue-keyed launch marker AppServer must have written before the
port was opened, records what it saw (or that it was absent) into a witness
file, optionally holds until a release file appears, and then delegates
unchanged to the deterministic app-server peer.

argv: marker_path witness_path hold_path fixture_script fixture_txt source
      [hold_timeout_seconds]
`hold_path` may be "-" for no hold. `hold_timeout_seconds` (default 60) bounds
the hold so a test can keep the held-worker window short; on expiry the worker
exits with status 4.
"""
import json
import os
import subprocess
import sys
import time

marker_path, witness_path, hold_path, fixture_script, fixture_txt, source = sys.argv[1:7]
hold_timeout = float(sys.argv[7]) if len(sys.argv) > 7 else 60.0

record = {"marker_path": marker_path, "exists": os.path.exists(marker_path)}

if record["exists"]:
    with open(marker_path, "r", encoding="utf-8") as stream:
        record["content"] = stream.read()

    try:
        identity = (json.loads(record["content"]).get("worker_identity") or {})
        receipt_path = identity.get("receipt_path")
        record["receipt_path"] = receipt_path
        record["receipt_exists_at_start"] = bool(receipt_path) and os.path.exists(receipt_path)
    except ValueError:
        record["receipt_exists_at_start"] = None

with open(witness_path, "w", encoding="utf-8") as stream:
    json.dump(record, stream)
    stream.flush()
    os.fsync(stream.fileno())

if hold_path != "-":
    deadline = time.monotonic() + hold_timeout
    while not os.path.exists(hold_path):
        if time.monotonic() > deadline:
            sys.stderr.write("fence probe hold timed out\n")
            sys.exit(4)
        time.sleep(0.05)

# Delegate to the deterministic peer without execv: on Windows, execv mangles
# interpreter paths containing spaces. Inherited stdio keeps the port stream
# intact and the peer remains inside the wrapper's job tree.
sys.exit(subprocess.call([sys.executable, "-u", fixture_script, fixture_txt, source]))
