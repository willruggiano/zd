"""Installed native capture/worker/Wayland restart check with ADAPTED decoding.
Real tiny.en model loading/state ownership. The test-only interposer holds the
old call after observing cancellation; a gate releases it only after new capture.
Not evidence of real whisper/CUDA cancellation timing or recognition quality.
"""
import json
from pathlib import Path
import subprocess
import sys
import time

binary, speech = sys.argv[1:]


def run(*args):
    return subprocess.check_output(args, timeout=10)


def eventually(predicate):
    end = time.monotonic() + 30
    while time.monotonic() < end:
        if predicate():
            return
        time.sleep(0.05)
    raise AssertionError("native restart effect did not arrive")


def node(name):
    return next((obj for obj in json.loads(run("pw-dump"))
                 if obj.get("info", {}).get("props", {}).get("node.name") == name), None)


def default(name):
    subprocess.run(["wpctl", "set-default", str(node(name)["id"])], check=True)
    time.sleep(0.4)


def log():
    return Path("daemon.log").read_text()


def toggle():
    subprocess.run([binary, "toggle"], check=True, timeout=3)


def clipboard():
    return run("wl-paste", "--no-newline")


def play(feed):
    subprocess.run(["pw-cat", "--playback", "--target", feed, speech], check=True, timeout=30)


eventually(lambda: node("test-mic-a") and node("test-mic-b"))
eventually(lambda: "model ready (explicit CPU build)" in log())
default("test-mic-a")
toggle()
eventually(lambda: "capture ready" in log())
play("test-feed-a")
eventually(lambda: "holding old operation" in log())
default("test-mic-b")
serial = node("test-mic-b")["info"]["props"]["object.serial"]
toggle()  # stop during background inference, not restart yet
assert "cancellation observed" not in log()
eventually(lambda: node("dictation.capture") is None)
toggle()
eventually(lambda: log().count("capture ready") == 2)
eventually(lambda: "cancellation observed" in log())
assert str(node("dictation.capture")["info"]["props"]["target.object"]) == str(serial)
assert clipboard() == b"Previous clipboard"
play("test-feed-b")  # replacement PCM arrives before old operation relinquishes its borrow
assert node("dictation.capture") is not None
assert log().count("test inference adapter: non-silent PCM") == 1
assert "borrowed PCM intact" not in log()
assert "session failed" not in log()
assert clipboard() == b"Previous clipboard"
toggle()
eventually(lambda: node("dictation.capture") is None)
assert "dictation: copied" not in log()
Path("restart-release").touch()
eventually(lambda: "dictation: copied" in log())
assert "borrowed PCM intact" in log()
count = log().count("test inference adapter: non-silent PCM") - 1
assert count >= 2
expected = " ".join(["Virtual microphone input reached inference."] * count).encode()
assert clipboard() == expected
assert log().count("dictation: copied") == 1
assert "session failed" not in log()
assert "Abandoned partial" not in log()
assert "Virtual microphone input" not in log()
assert log().count("model ready") == 1
