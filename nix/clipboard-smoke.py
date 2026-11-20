"""Real PipeWire/Wayland clipboard stress; explicitly substituted decoding only.
The interposer produces large, distinct results and holds each native decode at a
file gate. Readers use real ext-data-control receive requests into 4 KiB pipes.
No test adapter, gate, or reader helper ships in the installed daemon.
"""
import array
import fcntl
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import time

binary, reader = sys.argv[1:]
held = []
released = 0


def log():
    return Path("daemon.log").read_text()


class Reader:
    def __init__(self, mime="text/plain;charset=utf-8"):
        self.fd, writer = os.pipe()
        fcntl.fcntl(self.fd, fcntl.F_SETPIPE_SZ, 4096)
        os.set_blocking(self.fd, False)
        self.data = bytearray()
        self.eof = False
        try:
            subprocess.run([reader, str(writer), mime], pass_fds=(writer,), check=True, timeout=3)
        finally:
            os.close(writer)

    def progress(self, size=512):
        if self.eof:
            return
        try:
            data = os.read(self.fd, size)
        except BlockingIOError:
            return
        self.data.extend(data)
        self.eof = not data

    def drain(self):
        eventually(lambda: self.eof, lambda: self.progress(65536))
        result = bytes(self.data)
        self.close()
        return result

    def close(self):
        if self in held:
            held.remove(self)
        os.close(self.fd)


def eventually(predicate, progress=None, timeout=30):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        for pipe in held:
            pipe.progress()
        if progress:
            progress()
        if predicate():
            return
        time.sleep(0.03)
    raise AssertionError("native clipboard effect did not arrive")


def run(*args):
    return subprocess.check_output(args, timeout=5)


def node(name):
    return next((obj for obj in json.loads(run("pw-dump"))
                 if obj.get("info", {}).get("props", {}).get("node.name") == name), None)


def toggle():
    subprocess.run([binary, "toggle"], check=True, timeout=2)


def clipboard():
    return run("wl-paste", "--no-newline")


# A second of continuous speech-like non-silent PCM crosses a window boundary.
# The decoder is substituted, not the capture path. No audio is saved by dictation.
tone = array.array("f", (0.2 * math.sin(i * 0.1) for i in range(16000))).tobytes()


def start():
    count = log().count("capture ready")
    toggle()
    eventually(lambda: log().count("capture ready") == count + 1)
    subprocess.run(["pw-cat", "--playback", "--target", "test-feed-a", "--rate", "16000",
                    "--channels", "1", "--format", "f32", "--raw", "-"], input=tone, check=True, timeout=5)
    eventually(lambda: log().count("test clipboard: decode held") > released)
    assert node("dictation.capture") is not None
    assert "dictation: recording" in log()


def finish(letter, failure=False):
    global released
    copies = log().count("dictation: copied")
    failures = log().count("dictation: session failed")
    before = released
    toggle()
    eventually(lambda: node("dictation.capture") is None)

    def release():
        global released
        if log().count("test clipboard: decode held") > released:
            # Atomic gate publication: the worker must not read an empty file.
            Path("clipboard-gate").write_text(letter)
            Path("clipboard-gate").rename("clipboard-release")
            released += 1

    eventually(lambda: log().count("dictation: session failed" if failure else "dictation: copied")
               == (failures if failure else copies) + 1, release)
    assert log().count("dictation: copied") == copies + (not failure)
    assert log().count("dictation: session failed") == failures + failure
    # Every result exactly fills the configured transcript capacity. In
    # particular C must fail on offer slots, not an accidental text overflow.
    assert released - before == 2
    assert "TranscriptCapacity" not in log() and "AudioCapacity" not in log()
    return b" ".join([letter.encode() * 131072] * 2)


def request(mime="text/plain;charset=utf-8"):
    pipe = Reader(mime)
    held.append(pipe)
    eventually(lambda: len(pipe.data) > 0 or pipe.eof)
    return pipe


eventually(lambda: node("test-mic-a") is not None)
eventually(lambda: "model ready (explicit CPU build)" in log())
subprocess.run(["wpctl", "set-default", str(node("test-mic-a")["id"])], check=True)
time.sleep(0.4)
assert clipboard() == b"Previous clipboard"
start()
old_text = finish("A")
assert clipboard() == old_text
unsupported = request("application/x-unsupported")
assert unsupported.eof and not unsupported.data
unsupported.close()
# O_NONBLOCK cannot make arbitrary regular-file/device writes nonblocking.
# Those sinks are rejected rather than risking the capture loop.
fd = os.open("rejected-sink", os.O_CREAT | os.O_RDWR | os.O_EXCL, 0o600)
try:
    subprocess.run([reader, str(fd), "text/plain"], pass_fds=(fd,), check=True, timeout=3)
    time.sleep(0.1)
    assert os.fstat(fd).st_size == 0
finally:
    os.close(fd)
old = request()
concurrent = request("text/plain")
start()  # capture and background inference while two readers remain outstanding
assert clipboard() == old_text
assert len(old.data) < len(old_text) and not old.eof
new_text = finish("B")
assert clipboard() == new_text
assert concurrent.drain() == old_text  # not a mixture of A and B
assert not old.eof
start()
finish("C", failure=True)  # old reader + current owner fill both source slots
assert clipboard() == new_text
assert old.drain() == old_text
start()
current_text = finish("D")  # released old slot permits publication again
assert clipboard() == current_text

# Full transfer table: reject only the excess request, not the source or session.
readers = [request() for _ in range(3)]
excess = request()
assert excess.eof and not excess.data
excess.close()
readers[0].close()  # EPIPE releases that transfer; SIGPIPE must not kill daemon
# Allow a bounded event-loop turn, then prove another reader can receive all data.
time.sleep(0.1)
assert clipboard() == current_text
subprocess.run(["wl-copy"], input=b"External selection", check=True, timeout=3)
assert clipboard() == b"External selection"
assert readers[1].drain() == current_text

# A completely stalled request expires after five seconds without progress even
# after its source was cancelled. Any already buffered prefix is just a failed
# transfer, not a replacement of the offered transcript with truncated content.
stalled = readers[2]
held.remove(stalled)
time.sleep(5.3)
partial = stalled.drain()
assert len(partial) < len(current_text)
assert current_text.startswith(partial)
start()
assert clipboard() == b"External selection"
last = finish("E")
assert clipboard() == last
assert log().count("model ready") == 1
assert "AAAA" not in log() and "BBBB" not in log() and "DDDD" not in log()
print("real slow/concurrent readers, capture, ownership, exhaustion and reuse passed")
