"""Installed binary + real PipeWire/WirePlumber/whisper.cpp/Wayland, CPU tiny.en.
Only microphone input is virtual; JFK speech is the pinned upstream sample.
This is integration evidence, not RTX 3090 or dictation-quality acceptance.
"""
import json
from pathlib import Path
import subprocess
import sys
import time

binary, speech = sys.argv[1:3]
streaming = sys.argv[3:] == ["--streaming"]


def run(*args):
    return subprocess.check_output(args, timeout=10)


def eventually(predicate, timeout=90):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if predicate():
            return
        time.sleep(0.05)
    raise AssertionError("native effect did not arrive")


def nodes():
    return [obj for obj in json.loads(run("pw-dump"))
            if obj["type"] == "PipeWire:Interface:Node"]


def node(name):
    return next((obj for obj in nodes()
                 if obj["info"]["props"].get("node.name") == name), None)


def default(name):
    subprocess.run(["wpctl", "set-default", str(node(name)["id"])], check=True)
    # Wait for policy, metadata and the daemon's serialized registry callbacks.
    time.sleep(0.4)


def clipboard():
    return run("wl-paste", "--no-newline")


def log():
    return Path("daemon.log").read_text()


def toggle():
    subprocess.run([binary, "toggle"], check=True, timeout=3)


eventually(lambda: node("test-mic-a") and node("test-mic-b"))
eventually(lambda: "model ready (explicit CPU build)" in log())
duplicate = subprocess.run([binary, "daemon"], capture_output=True, timeout=10)
assert duplicate.returncode == 1 and b"ControlAlreadyRunning" in duplicate.stderr
assert node("dictation.capture") is None
assert clipboard() == b"Previous clipboard"

for index, (source, other, feed) in enumerate([
        ("test-mic-a", "test-mic-b", "test-feed-a"),
        ("test-mic-b", "test-mic-a", "test-feed-b")]):
    default(source)
    serial = node(source)["info"]["props"]["object.serial"]
    previous = clipboard()
    decoded_before = log().count("dictation: window decoded")
    toggle()
    eventually(lambda: log().count("capture ready") == index + 1)
    assert str(node("dictation.capture")["info"]["props"]["target.object"]) == str(serial)
    default(other)
    # A default change cannot retarget an in-progress recording.
    assert str(node("dictation.capture")["info"]["props"]["target.object"]) == str(serial)
    subprocess.run(["pw-cat", "--playback", "--target", feed, speech], check=True, timeout=40)
    time.sleep(0.3)
    assert clipboard() == previous
    if streaming:
        # A forced ten-second window finishes while capture is still active.
        # Keep the microphone open until actual CPU completion, not merely enqueue.
        eventually(lambda: log().count("dictation: window decoded") > decoded_before)
        assert node("dictation.capture") is not None
        assert clipboard() == previous
        assert log().count("dictation: copied") == index
    toggle()
    eventually(lambda: node("dictation.capture") is None)
    eventually(lambda: log().count("dictation: copied") == index + 1)
    if streaming:
        eventually(lambda: log().count("dictation: window decoded") >= decoded_before + 2)
    result = clipboard().lower()
    assert b"ask not what your country" in result, result
    assert b"ask not" not in log().lower().encode()
    assert log().count("model ready") == 1

# Genuine silence should close capture without running/publishing a hallucination.
previous = clipboard()
default("test-mic-a")
toggle()
eventually(lambda: log().count("capture ready") == 3)
time.sleep(0.3)
toggle()
eventually(lambda: "dictation: no speech" in log())
assert node("dictation.capture") is None
assert clipboard() == previous

# Missing default is not permission to choose an arbitrary source.
subprocess.run(["pw-metadata", "-n", "default", "0", "default.audio.source",
                '{"name":"absent-test-source"}', "Spa:String:JSON"], check=True)
time.sleep(0.3)
toggle()
eventually(lambda: "session failed" in log())
assert node("dictation.capture") is None
assert clipboard() == previous
