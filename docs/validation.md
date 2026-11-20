# Target desktop/GPU validation (09)

**Pending.** Headless/native consumers do not validate the user's RTX 3090,
physical microphones, monitor appearance or recognition quality. The development
workspace has no connected Wayland desktop or NVIDIA device. Cleanup (10) stays
blocked until this acceptance and any resulting fixes are complete.

Use the [installation guide](installation.md) to deploy `nixosModules.default`
with the existing generic graphical-session lifecycle and imported Wayland
environment. Do not run fixture mode, use a test decoder interposer, or substitute
tiny.en/CPU for the intended CUDA/large-v3-turbo acceptance. Upstream CPU fallback
is allowed in production, but is **not** a passing CUDA validation result.

## Record the environment

Record the exact application revision/Nix store executable and model path/hash,
flake lock, NixOS generation, actual compositor/version and advertised protocols,
output count/modes/scales, microphone type, and ordinary background workload.
Do not assume the previously reported GPU/driver versions are still current.

```sh
readlink -f /run/current-system/sw/bin/dictation
dictation footprint
systemctl --user show dictation -p MainPID -p ExecStart -p ActiveState
systemctl --user show-environment | rg '^(WAYLAND_DISPLAY|XDG_RUNTIME_DIR)='
wayland-info                         # requires wayland-utils
wpctl status
nvidia-smi --query-gpu=name,uuid,driver_version,memory.total --format=csv
```

The selected **build toolkit** is CUDA 12.9 (nvcc 12.9.86, architecture 86),
separate from the driver/UMD versions. Check the deployed flake if it changes.
Keep environment metadata local/redact device identifiers before sharing.

## Measure, do not infer

In separate terminals during deliberately non-sensitive test dictation:

```sh
journalctl --user -u dictation -f -o short-monotonic
nvidia-smi pmon -s um -d 1
nvidia-smi --query-compute-apps=pid,process_name,used_gpu_memory --format=csv -l 1
# Inspect process RAM after loading and after the workload:
pid=$(systemctl --user show dictation -p MainPID --value)
rg '^(VmRSS|VmHWM):' /proc/"$pid"/status
```

Correlate GPU compute activity with this daemon's PID **during decoding**, not
just model residency or another GPU process. Record unsupported measurement
commands as such and use an available GPU profiler if needed; absence of a
fallback warning or successful build/readiness alone is not CUDA evidence.
Record observed peak GPU memory and process RAM separately from `static_bytes`,
which excludes native/GPU allocations and Wayland pixel backing.

Record capture duration, per-window decode start/completion times from sanitized
phase logs, stop-to-copy latency, and restart-to-new-capture latency. Exercise
continuous speech longer than two minutes across several maximum-size windows
and pauses as a separate case. Decode times must sustain capture under ordinary
load without accumulating backlog; no numeric latency promise is assumed.
Short pause-ended windows have different durations: do not divide all decode
times by the configured maximum and call that measured throughput.

## Acceptance checklist

Record pass/fail, measurement/observation, configuration and any defect for each:

- [ ] Generic session start/stop and PipeWire ordering; missing Wayland environment
  gates service startup. Local-model-path override loads without runtime download.
- [ ] Loading toggle shows loading but opens no microphone and queues no recording.
  Once ready, the intended model uses CUDA; subsequent sessions reuse residency.
- [ ] Representative English coding-agent replies: punctuation, technical terms,
  pauses and continuous speech. Review boundary joins for omitted/repeated words;
  paste into an unrelated application. Do not retain recordings/transcript history.
- [ ] More than two minutes of capture and many windows; no timer cutoff or partial
  clipboard updates. Record throughput, finalization latency and RAM/VRAM peaks.
- [ ] Repeated restart during finalization: immediate replacement capture while old
  decoding unwinds, no stale copy. Toggle during background decoding still stops.
- [ ] Previous transcript pasteable during capture/inference and replacement;
  overlapping/slow readers do not mix text or block controls.
- [ ] Silence, empty recognition, missing/default-changed/removed microphone,
  dependency loss and retry follow the documented failure/restart policy.
- [ ] Deliberately small valid transcript/audio/output/reader capacities fail
  explicitly, without silent drops/truncation. Restore normal settings afterward.
- [ ] Every monitor shows the bottom-center pill, reactive bars and distinct phases.
  Check mixed scales, mode changes, unplug/replug, all outputs gone/returned, and
  a new recording before old feedback expires. No transcript appears in the pill.
- [ ] A focused unrelated application keeps keyboard focus across every phase and
  hotplug. Click through the pill onto a known underlying control; verify the
  control receives the click. Headless protocol assertions alone do not pass this.
- [ ] No dictated contents in logs, saved audio or application transcript history.
  Clipboard managers can independently retain text. Lock alone does not cancel;
  there are no bespoke lock/suspend hooks or guaranteed suspend cancellation.
- [ ] Review [storage/lifetime evidence](runtime.md#static-storage-and-allocation-audit),
  standard Zig test results and separately executed named consumers. Keep cached,
  evaluated, executed and target-hardware results distinct.

Preserve measurements, defects/fixes and final acceptance here (or link a durable
report) before completing 09. Rerun affected target checks after cleanup replaces
native integrations; pre-cleanup acceptance cannot certify new bindings.

## Results

No target measurements have been obtained in this workspace. All boxes remain
pending; see [recorded local verification](runtime.md) for what actually ran.
