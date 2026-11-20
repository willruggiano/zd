"""Real installed capture/Wayland, explicit test-only decoder interposition.
Two device slots: pinning, removal, reuse, retry during cancellation, silence,
empty decode, decode failure, and fatal connection/capacity teardown.
No GPU or recognition-quality claim. Only non-sensitive synthetic PCM is used.
"""
import array
import json
import math
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

binary, disconnect, audio_server, compositor = sys.argv[1:]


def run(*args):
    return subprocess.check_output(args, timeout=10)


def log():
    return Path("daemon.log").read_text()


def eventually(predicate):
    end = time.monotonic() + 30
    while time.monotonic() < end:
        if predicate():
            return
        time.sleep(0.05)
    raise AssertionError("native recovery effect did not arrive")


def node(name):
    return next((obj for obj in json.loads(run("pw-dump"))
                 if obj.get("info", {}).get("props", {}).get("node.name") == name), None)


def default(name):
    subprocess.run(["wpctl", "set-default", str(node(name)["id"])], check=True)
    time.sleep(0.3)


def toggle():
    subprocess.run([binary, "toggle"], check=True, timeout=3)


def start():
    ready = log().count("capture ready")
    toggle()
    eventually(lambda: log().count("capture ready") == ready + 1)
    assert node("dictation.capture") is not None


def stop():
    toggle()
    eventually(lambda: node("dictation.capture") is None)


def clipboard():
    return run("wl-paste", "--no-newline")


def play(feed, seconds=0.25):
    # Test-owned PCM, never written to a recording file. Real pw-cat transport.
    pcm = array.array("f", (0.2 * math.sin(2 * math.pi * 220 * i / 16000)
                            for i in range(int(16000 * seconds))))
    subprocess.run(["pw-cat", "--playback", "--raw", "--rate", "16000", "--channels", "1",
                    "--format", "f32", "--target", feed, "-"],
                   input=pcm.tobytes(), check=True, timeout=10)


def successful_reply():
    copied = log().count("dictation: copied")
    decoded = log().count("test inference adapter: non-silent PCM")
    previous = clipboard()
    start()
    play("test-feed-b")
    assert clipboard() == previous
    stop()
    eventually(lambda: log().count("dictation: copied") == copied + 1)
    chunks = log().count("test inference adapter: non-silent PCM") - decoded
    assert chunks >= 1
    assert clipboard() == b" ".join([b"Virtual microphone input reached inference."] * chunks)


eventually(lambda: node("test-mic-a") and node("test-mic-b"))
eventually(lambda: "model ready (explicit CPU build)" in log())
assert node("dictation.capture") is None
assert clipboard() == b"Previous clipboard"
default("test-mic-a")
start()
serial = node("test-mic-a")["info"]["props"]["object.serial"]
default("test-mic-b")
assert str(node("dictation.capture")["info"]["props"]["target.object"]) == str(serial)
play("test-feed-a", 1.5)
eventually(lambda: "holding old operation" in log())
subprocess.run(["pw-cli", "destroy", str(node("test-mic-a")["id"])], check=True)
eventually(lambda: node("dictation.capture") is None)
eventually(lambda: "session failed" in log())
eventually(lambda: "cancellation observed" in log())
assert "MicrophoneRemoved" in log() or "CaptureDisconnected" in log()
assert clipboard() == b"Previous clipboard"
# Retry without waiting for the old decoder. Its PCM remains borrowed until gate.
start()
assert str(node("dictation.capture")["info"]["props"]["target.object"]) == str(
    node("test-mic-b")["info"]["props"]["object.serial"])
play("test-feed-b")
stop()
assert "borrowed PCM intact" not in log()
assert "dictation: copied" not in log()
Path("restart-release").touch()
eventually(lambda: "dictation: copied" in log())
assert "borrowed PCM intact" in log()
assert log().count("dictation: copied") == 1
assert b"Virtual microphone input" in clipboard()

for _ in range(3):
    previous = clipboard()
    decoded = log().count("test inference adapter: non-silent PCM")
    no_speech = log().count("dictation: no speech")
    start()  # silence never invokes decode
    stop()
    eventually(lambda: log().count("dictation: no speech") == no_speech + 1)
    assert log().count("test inference adapter: non-silent PCM") == decoded
    assert clipboard() == previous

    for outcome in ("empty", "fail"):
        marker = Path("recovery-" + outcome)
        marker.touch()
        expected = "dictation: no speech" if outcome == "empty" else "session failed"
        before = log().count(expected)
        start()
        play("test-feed-b")
        # Failure may occur during capture if a window was already sealed.
        if node("dictation.capture") is not None:
            stop()
        eventually(lambda: log().count(expected) == before + 1)
        eventually(lambda: node("dictation.capture") is None)
        assert clipboard() == previous
        marker.unlink()
    assert "InferenceFailure" in log()

    failed = log().count("session failed")
    subprocess.run(["pw-metadata", "-n", "default", "0", "default.audio.source",
                    '{"name":"absent-test-source"}', "Spa:String:JSON"], check=True)
    time.sleep(0.3)
    toggle()
    eventually(lambda: log().count("session failed") == failed + 1)
    assert "DefaultMicrophoneUnavailable" in log()
    assert node("dictation.capture") is None
    assert clipboard() == previous
    # Undo our direct metadata injection. Re-setting the already configured
    # wpctl default alone need not cause policy to rewrite default.audio.source.
    subprocess.run(["pw-metadata", "-n", "default", "0", "default.audio.source",
                    '{"name":"test-mic-b"}', "Spa:String:JSON"], check=True)
    default("test-mic-b")
    successful_reply()

# Repeated removal/addition recycles the second device slot rather than growing it.
# pw-loopback keeps test-created objects alive until the helper exits.
for _ in range(4):
    helper = subprocess.Popen(["pw-loopback", "--capture-props", "node.name=recovery-feed media.class=Audio/Sink",
                               "--playback-props", "node.name=recovery-mic media.class=Audio/Source"])
    try:
        eventually(lambda: node("recovery-mic") is not None)
        default("recovery-mic")
        start()
    finally:
        helper.terminate()
        helper.wait(timeout=5)
    eventually(lambda: node("recovery-mic") is None and node("dictation.capture") is None)
    default("test-mic-b")
successful_reply()
assert log().count("model ready") == 1
assert "Abandoned partial" not in log()
assert "Virtual microphone input reached inference" not in log()

# Fatal dependencies use diagnostics/exit, never fictitious on-screen success.
# An independently owned selection survives daemon exit (but not compositor loss).
subprocess.run(["wl-copy"], input=b"External clipboard survives", check=True)
assert clipboard() == b"External clipboard survives"
start()
copied = log().count("dictation: copied")
if disconnect == "capacity":
    helpers = []
    try:
        for i in range(2):
            helpers.append(subprocess.Popen(["pw-loopback", "--capture-props", f"node.name=extra-feed-{i} media.class=Audio/Sink",
                                              "--playback-props", f"node.name=extra-mic-{i} media.class=Audio/Source"]))
            eventually(lambda: node(f"extra-mic-{i}") is not None)
        eventually(lambda: "DeviceCapacity" in log())
        eventually(lambda: node("dictation.capture") is None)
    finally:
        for helper in helpers:
            helper.terminate()
            helper.wait(timeout=5)
else:
    os.kill(int(audio_server if disconnect == "pipewire" else compositor), signal.SIGTERM)
    eventually(lambda: ("PipeWireDisconnected" if disconnect == "pipewire" else "WaylandDisconnected") in log())
    if disconnect == "wayland":
        eventually(lambda: node("dictation.capture") is None)
assert log().count("dictation: copied") == copied
if disconnect != "wayland":
    assert clipboard() == b"External clipboard survives"
if disconnect in ("pipewire", "wayland"):
    unavailable = subprocess.run([binary, "daemon"], capture_output=True, timeout=30)
    assert unavailable.returncode == 1
    errors = (b"PipeWireConnection", b"PipeWireDisconnected") if disconnect == "pipewire" else (b"WaylandConnection",)
    assert any(error in unavailable.stderr for error in errors), unavailable.stderr
    assert b"dictation: recording" not in unavailable.stderr
    assert b"FIXTURE" not in unavailable.stderr
