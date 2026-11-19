"""Separate installed-package/native Wayland check; never part of checkPhase."""
import os
import socket
import subprocess
import sys
import time

binary = sys.argv[1]
address = b"\0dictation-" + str(os.getuid()).encode()


def clipboard():
    return subprocess.check_output(["wl-paste", "--no-newline"], timeout=3)


def toggle():
    subprocess.run([binary, "toggle"], check=True, timeout=3)


def request(value):
    with socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET) as peer:
        peer.settimeout(2)
        peer.connect(address)
        peer.send(value)
        return peer.recv(64)


def eventually(predicate):
    end = time.monotonic() + 5
    while time.monotonic() < end:
        if predicate():
            return
        time.sleep(0.03)
    raise AssertionError("native effect did not arrive")


for invalid in [b"no", b"toggle\n", b"toggle\0", b"x" * 4096]:
    assert request(invalid) == b"invalid"
assert clipboard() == b"Previous clipboard"

# Fill every control slot with idle peers. A further peer must not be accepted
# as a toggle; bounded idle deadlines subsequently make the service usable.
footprint = dict(line.split("=") for line in subprocess.check_output(
    [binary, "footprint"], text=True).splitlines())
peers = []
try:
    for _ in range(int(footprint["control_clients"])):
        peer = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
        peer.connect(address)
        peers.append(peer)
    time.sleep(0.1)
    try:
        assert request(b"toggle") == b"busy"
    except (ConnectionResetError, BrokenPipeError):
        # A full server cannot retain another peer. Closing a seqpacket socket
        # with unread peer data may reset it before its best-effort busy reply.
        pass
    # Idle deadlines reclaim capacity even if the peers never disconnect.
    time.sleep(1.1)
    assert request(b"not-a-toggle") == b"invalid"
finally:
    for peer in peers:
        peer.close()
time.sleep(0.1)
assert clipboard() == b"Previous clipboard"

toggle()
assert clipboard() == b"Previous clipboard"
toggle()
eventually(lambda: clipboard() == b"Fixture dictation result.")
# The offer remains usable after finalization and while another session runs.
toggle()
assert clipboard() == b"Fixture dictation result."
toggle()
time.sleep(0.5)  # allow the second fixture finalization/source replacement
assert clipboard() == b"Fixture dictation result."
# External ownership cancels our source; the next session must preserve it
# until publication, then safely reuse an available source slot.
subprocess.run(["wl-copy"], input=b"External text", check=True, timeout=3)
eventually(lambda: clipboard() == b"External text")
toggle()
assert clipboard() == b"External text"
toggle()
eventually(lambda: clipboard() == b"Fixture dictation result.")
# A disconnect without a command does not damage the next control request.
with socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET) as peer:
    peer.connect(address)
time.sleep(0.1)
assert request(b"garbage") == b"invalid"
assert int(footprint["static_bytes"]) > int(footprint["transcript_bytes"]) * 4
