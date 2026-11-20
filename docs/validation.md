# Target desktop/GPU validation

Use this procedure for tests of the actual desktop, microphone and GPU.
Record acceptance only for the tested revision.
See [results](#results) for status.

Use the [installation guide](installation.md) to deploy `nixosModules.default`.
Use the existing generic graphical-session lifecycle and imported Wayland
environment. Do not run fixture mode. Do not use a test decoder interposer.
Do not substitute tiny.en or CPU inference for CUDA/large-v3-turbo acceptance.
Production permits upstream CPU fallback, but fallback does **not** pass CUDA validation.

## Record the environment

Record these items:

- Exact application revision and Nix store executable.
- Model path and hash, flake lock and NixOS generation.
- Actual compositor, version and advertised protocols.
- Output count, modes and scales.
- Microphone type and normal background workload.

Do not assume that previously reported GPU or driver versions are current.

```sh
readlink -f /run/current-system/sw/bin/dictation
dictation footprint
systemctl --user show dictation -p MainPID -p ExecStart -p ActiveState
systemctl --user show-environment | rg '^(WAYLAND_DISPLAY|XDG_RUNTIME_DIR)='
wayland-info                         # requires wayland-utils
wpctl status
nvidia-smi --query-gpu=name,uuid,driver_version,memory.total --format=csv
```

Record the deployed [build toolkit](runtime.md#dependencies-and-provisioning)
separately from the driver and UMD versions.
Keep environment metadata local. Before you share it, remove device identifiers.

## Measure, do not infer

Use test dictation without private content.
During dictation, run these commands in separate terminals:

```sh
journalctl --user -u dictation -f -o short-monotonic
nvidia-smi pmon -s um -d 1
nvidia-smi --query-compute-apps=pid,process_name,used_gpu_memory --format=csv -l 1
# Inspect process RAM after loading and after the workload:
pid=$(systemctl --user show dictation -p MainPID --value)
rg '^(VmRSS|VmHWM):' /proc/"$pid"/status
```

Match GPU compute activity to this daemon's PID **during decoding**.
Model residency or activity from another GPU process is not sufficient.
If a measurement command is unsupported, record that limitation.
If necessary, use an available GPU profiler.
The absence of a fallback warning does not prove CUDA execution.
A successful build or ready state does not prove it either.

Record peak GPU memory and process RAM separately from `static_bytes`.
That field excludes native allocations, GPU allocations and Wayland pixel backing.
Record these times from sanitized phase logs and observations:

- Capture duration.
- Start and completion of each window decode.
- Stop-to-copy latency.
- Restart-to-new-capture latency.

Use continuous speech longer than two minutes across several maximum-size windows.
Do a separate test with pauses.
Decode throughput must sustain capture under normal load without an increasing backlog.
There is no numeric latency promise.
Windows that end at pauses can be shorter than the configured maximum.
Do not divide all decode times by that maximum and report the result as measured throughput.

## Acceptance checklist

For each item, record pass or fail, measurements or observations, configuration
and defects:

- [ ] Do tests for generic session start, stop and PipeWire ordering.
  Make sure that missing Wayland environment prevents startup.
  Make sure that a local-model-path override loads without a runtime download.
- [ ] Toggle during loading. Make sure that loading feedback appears without microphone capture
  or a queued recording. After readiness, make sure that the intended model uses CUDA.
  Make sure that later sessions reuse the loaded model.
- [ ] Dictate representative English replies to coding agents.
  Include punctuation, technical terms, pauses and continuous speech.
  Examine boundary joins for missing or repeated words.
  Paste into an unrelated application. Do not keep recordings or transcript history.
- [ ] Record more than two minutes of speech across many windows.
  Make sure that no timer stops recording and no partial text reaches the clipboard.
  Record throughput, finalization latency and peak RAM and VRAM use.
- [ ] Restart repeatedly during finalization.
  Make sure that replacement capture starts immediately, before old decoding returns.
  Make sure that old results cannot publish.
  Make sure that a toggle during background decoding still stops recording.
- [ ] Paste the previous transcript during capture, inference and replacement.
  Make sure that concurrent or slow readers do not mix text or block controls.
- [ ] Do tests for silence, empty recognition and microphone loss.
  Do tests for a missing microphone and a change to the default microphone.
  Do tests for dependency loss and retry.
  Make sure that failure and restart behavior agrees with the documentation.
- [ ] Use small, valid transcript, audio, output and reader capacities.
  Make sure that capacity exhaustion causes explicit failure, without silent loss or truncation.
  Restore normal settings afterward.
- [ ] Examine the bottom-center pill, reactive bars and distinct phases on every monitor.
  Do tests with mixed scales, mode changes and output removal and reconnection.
  Do a test with loss and return of all outputs.
  Start a new recording before old feedback expires.
  Make sure that the pill never shows transcript text.
- [ ] Make sure that an unrelated application keeps keyboard focus across every phase and output change.
  Click through the pill onto a known control below it.
  Make sure that the control receives the click.
  Headless protocol assertions alone do not pass this requirement.
- [ ] Make sure that the application saves no audio, transcript history or dictated contents in logs.
  External clipboard managers can keep copied text independently.
  A screen lock alone does not cancel recording.
  There are no special lock or suspend hooks. Suspend does not guarantee cancellation.
- [ ] Review [storage and lifetime evidence](runtime.md#static-storage-and-allocation-audit).
  Review standard Zig test results and separately executed named consumers.
  Distinguish cached results, evaluation, execution and target-hardware results.

Keep measurements, defects, fixes and acceptance in this guide, or link a lasting report.
After an integration change, rerun the applicable checks.
Acceptance of an old implementation does not certify its replacement.

## Results

**Pending.** This workspace has no connected target desktop or NVIDIA device.
No target measurements are available. All boxes remain unchecked.
See [local verification evidence](verification.md) for checks that ran.
Headless, native and VM results do not establish hardware acceptance.
