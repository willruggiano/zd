# Consumer-level VM test: real systemd user manager, PipeWire/WirePlumber,
# headless Sway, native indicator/clipboard and real CPU whisper model loading.
# Decoding uses an explicit non-silent-PCM adapter, not speech recognition.
# Microphone/display are virtual; this does not validate a target GPU.
import json
import shlex


def command(script: str) -> str:
    # Environment here belongs to a command, NOT to the user manager.
    prefix = "export XDG_RUNTIME_DIR=/run/user/1000; "
    if display:
        prefix += f"export WAYLAND_DISPLAY={shlex.quote(display)}; "
    return "su - alice -c " + shlex.quote(prefix + script)


def user(script: str) -> str:
    return machine.succeed(command(script))


def wait(script: str) -> None:
    machine.wait_until_succeeds(command(script), timeout=600)


def service(args: str) -> str:
    return user("systemctl --user " + args)


def daemon_log() -> str:
    return user("journalctl --user -u dictation.service -b --no-pager -o cat")


def capture_present() -> str:
    return "pw-dump | jq -e 'any(.[]; .info.props[\"node.name\"] == \"dictation.capture\")'"


def capture_absent() -> str:
    return "pw-dump | jq -e 'all(.[]; .info.props[\"node.name\"] != \"dictation.capture\")'"


display = ""
start_all()
# TCG may need longer than the driver's fixed five-minute shell handshake.
machine.wait_for_console_text("connecting to host", timeout=900)
machine.wait_for_unit("multi-user.target")
machine.succeed("loginctl enable-linger alice")
machine.wait_for_unit("user@1000.service")
service("start test-compositor.service")
wait("test -S /run/user/1000/wayland-1 || test -S /run/user/1000/wayland-0")
display = user("for f in /run/user/1000/wayland-*; do if test -S \"$f\"; then basename \"$f\"; break; fi; done").strip()

with subtest("a shell environment and target start do not import Wayland into the manager"):
    service("unset-environment WAYLAND_DISPLAY")
    service("start test-desktop.target")
    assert service("show dictation.service -p ConditionResult --value").strip() == "no"
    assert service("show dictation.service -p MainPID --value").strip() == "0"
    machine.fail(command("dictation toggle"))
    service("stop test-desktop.target")

with subtest("imported environment permits startup, but a missing configured model is not ready"):
    service("import-environment WAYLAND_DISPLAY")
    service("start test-desktop.target")
    machine.wait_for_unit("dictation.service", user="alice")
    wait("journalctl --user -u dictation.service -b -o cat | grep -q ModelBackendInitialization")
    assert "model ready" not in daemon_log()
    user("printf 'Previous clipboard' | wl-copy")
    user("dictation toggle")
    wait(capture_absent())
    assert user("wl-paste --no-newline") == "Previous clipboard"
    service("stop test-desktop.target")

with subtest("module package, local model and all sizing overrides reach the installed daemon"):
    user(f"cp {shlex.quote(model)} /home/alice/model.bin")
    service("start test-desktop.target")
    wait("journalctl --user -u dictation.service -b -o cat | grep -q 'model ready (explicit CPU build)'")
    pid = service("show dictation.service -p MainPID --value").strip()
    assert machine.succeed(f"ps -o uid= -p {pid}").strip() == "1000"
    assert machine.succeed(f"readlink /proc/{pid}/exe").strip() == binary
    footprint = dict(line.split("=") for line in user("dictation footprint").splitlines())
    expected = dict(transcript_bytes=4096, control_clients=4, clipboard_slots=2,
                    transfers=2, audio_samples=640000, device_slots=4,
                    worker_stack_bytes=2097152, inference_threads=2)
    assert all(int(footprint[k]) == v for k, v in expected.items())
    assert int(footprint["static_bytes"]) % int(footprint["alignment"]) == 0
    wait("pw-dump | jq -e 'any(.[]; .info.props[\"node.name\"] == \"test-mic\")'")
    # PipeWire being active is not evidence of an available default microphone.
    user("pw-metadata -n default 0 default.audio.source '{\"name\":\"missing-source\"}' Spa:String:JSON")
    machine.sleep(1)
    user("dictation toggle")
    wait("journalctl --user -u dictation.service -b -o cat | grep -q DefaultMicrophoneUnavailable")
    wait(capture_absent())
    assert user("wl-paste --no-newline") == "Previous clipboard"

with subtest("installed toggle drives real capture, visible indicator and native clipboard"):
    nodes = json.loads(user("pw-dump"))
    source = next(n for n in nodes if n.get("info", {}).get("props", {}).get("node.name") == "test-mic")
    user(f"wpctl set-default {source['id']}")
    machine.sleep(2)  # metadata delivery and the failure pulse clearing
    user("grim /home/alice/idle.png")
    # Use one user shell for the active recording: repeated PAM/driver roundtrips
    # under TCG otherwise consume the bounded short-reply audio bank themselves.
    ready = "until journalctl --user -u dictation.service -b -o cat | grep -q 'capture ready'; do sleep .1; done"
    user(
        "set -euo pipefail; dictation toggle; "
        f"timeout 15 bash -c {shlex.quote(ready)}; "
        + capture_present() + "; grim /home/alice/recording.png; "
        f"pw-cat --playback --target test-feed {shlex.quote(speech)}; "
        "test \"$(wl-paste --no-newline)\" = 'Previous clipboard'; dictation toggle"
    )
    wait(capture_absent())
    assert "AudioCapacity" not in daemon_log()
    user("python3 -c 'from PIL import Image; assert Image.open(\"/home/alice/idle.png\").convert(\"RGB\").tobytes() != Image.open(\"/home/alice/recording.png\").convert(\"RGB\").tobytes()'")
    wait("journalctl --user -u dictation.service -b -o cat | grep -q 'dictation: copied'")
    assert user("wl-paste --no-newline") == "Virtual microphone input reached inference."
    journal = daemon_log()
    assert "Virtual microphone input reached inference" not in journal
    assert journal.count("test inference adapter: non-silent PCM") == 1
    assert journal.count("model ready") == 1

with subtest("desktop shutdown stops the service and releases active capture and clipboard ownership"):
    user("dictation toggle")
    wait(capture_present())
    service("stop test-desktop.target")
    wait("! systemctl --user is-active --quiet graphical-session.target")
    wait("! systemctl --user is-active --quiet dictation.service")
    assert service("show dictation.service -p MainPID --value").strip() == "0"
    assert service("show dictation.service -p Result --value").strip() == "success"
    wait(capture_absent())
    machine.fail(command("dictation toggle"))
    machine.fail(command("wl-paste --no-newline"))
    service("unset-environment WAYLAND_DISPLAY")
    service("start test-desktop.target")
    assert service("show dictation.service -p ConditionResult --value").strip() == "no"
    assert service("show dictation.service -p MainPID --value").strip() == "0"
    service("stop test-desktop.target test-compositor.service")

machine.copy_from_machine("/home/alice/recording.png", "screenshots")
