"""Real native startup with an intentionally missing build-configured model."""
import json
from pathlib import Path
import subprocess
import sys
import time

binary = sys.argv[1]
end = time.monotonic() + 15
while "ModelBackendInitialization" not in Path("daemon.log").read_text():
    assert time.monotonic() < end
    time.sleep(0.05)
for _ in range(2):
    subprocess.run([binary, "toggle"], check=True, timeout=3)
    nodes = json.loads(subprocess.check_output(["pw-dump"], timeout=5))
    assert not any(obj.get("info", {}).get("props", {}).get("node.name") == "dictation.capture" for obj in nodes)
    assert subprocess.check_output(["wl-paste", "--no-newline"], timeout=3) == b"Previous clipboard"
assert "model ready" not in Path("daemon.log").read_text()
assert "FIXTURE" not in Path("daemon.log").read_text()
