# NixOS graphical-session installation

The flake exports **`nixosModules.default`**. Use this checkout (for example a
`git+file:///absolute/path/to/dictation?ref=next` flake input), or a published
revision containing this module, as your `zd` input; pin it in `flake.lock`.
Add it to your existing NixOS configuration's module list:

```nix
modules = [
  ./configuration.nix
  inputs.zd.nixosModules.default
  { services.dictation.enable = true; }
];
```

Rebuild/switch the system normally. The module installs `dictation` in the system
profile and a **systemd user service**, not a root microphone daemon. Bind
`dictation toggle` in your existing shortcut launcher. One press records; the
next closes capture, finalizes and copies. Another press during finalization
discards that session and starts a fresh recording without waiting for old inference.
Paste manually. The current streaming limitations still apply; see [runtime behavior](runtime.md).

## Desktop and driver prerequisites

- A compositor implementing **layer-shell and ext-data-control-v1**. Stock
  GNOME/Mutter is not supported. There is no compositor-specific fallback.
- A functioning Wayland session and its normal `XDG_RUNTIME_DIR`. No Home Manager,
  UWSM or Hyprland module/package is required or enabled by this module.
- The default package uses **CUDA/large-v3-turbo**, provisioned and hash-pinned by
  Nix. Its NVIDIA driver must already be installed and compatible, with driver
  libraries available through `/run/opengl-driver/lib`. The module does not set
  up a GPU driver or select a compositor. The flake permits its unfree CUDA
  toolkit dependencies; application code remains MIT licensed.
- The module enables user PipeWire and its audio support. NixOS normally enables
  WirePlumber with PipeWire and makes it wanted by `pipewire.service`; no separate
  session-manager launcher is installed. Do not configure system-wide PipeWire
  for this user-service integration.

The service has `WantedBy` and `PartOf` on `graphical-session.target`, `Wants` and
`After` on `pipewire.service`, and `ConditionEnvironment=WAYLAND_DISPLAY`.
**Ordering after PipeWire is not microphone readiness.** The application still
resolves the current default source when recording begins and refuses capture
when none is available. Model readiness is separate again: wait for
`model ready (GPU requested; CPU fallback allowed)` (or the explicitly selected
CPU equivalent).
GPU initialization may fall back to CPU with a warning; readiness is not proof of
CUDA execution. A systemd `active` state does not mean a model has loaded
successfully.

## The desktop owns the session

`ConditionEnvironment` checks the **user manager's environment**, not just the
terminal or shortcut launcher's environment. Once the compositor's socket exists,
your existing desktop session startup must import the relevant variables before
activating its session target:

```sh
systemctl --user import-environment WAYLAND_DISPLAY
# Your desktop then starts its normal session target.
```

`XDG_RUNTIME_DIR` is normally supplied by logind/PAM; the compositor must belong
to that same user/runtime directory. Import only intended variables, not the
entire shell environment. **Starting a named target never imports environment
variables.** The generic target is not a compositor launcher or a session
supervisor: the containing desktop owns its lifetime. In the pinned systemd it
also has `RefuseManualStart=yes` and `StopWhenUnneeded=yes`.

If your existing session setup does not already own the generic target, a
minimal desktop-owned target can be declared alongside the module:

```nix
systemd.user.targets.my-desktop = {
  bindsTo = [ "graphical-session.target" ];
  after = [ "graphical-session.target" ];
};
```

Your desktop's lifecycle hooks then perform:

```sh
# Startup, after WAYLAND_DISPLAY is set and its socket is ready:
systemctl --user import-environment WAYLAND_DISPLAY
systemctl --user start my-desktop.target

# Logout/desktop teardown, before removing its environment:
systemctl --user stop my-desktop.target
systemctl --user unset-environment WAYLAND_DISPLAY
```

This is an example for the existing session owner, **not** an application helper
or a replacement desktop manager. Do not add it when the desktop already owns a
session target. Leaving a session target active after logout also leaves its
services active; lingering alone does not represent a graphical session. There
is one dictation daemon per UID, not independent daemons per simultaneous display.

After enabling/updating the module during an already-running graphical session:

```sh
systemctl --user daemon-reload
systemctl --user import-environment WAYLAND_DISPLAY
systemctl --user restart dictation.service
journalctl --user -u dictation.service -b
```

A missing environment causes a condition skip, not successful startup. Importing
a variable does not itself retry a skipped unit; start/restart it (or begin the
next desktop session). A present but invalid display or unsupported protocol
fails with sanitized application diagnostics. For deliberate shutdown of only
dictation use `systemctl --user stop dictation.service`; stopping the desktop's
target also affects its other services.

## Model and whole-program storage configuration

Options live under `services.dictation`. `package` selects the base package;
`modelPath` defaults to that package's provisioned model. For example:

```nix
services.dictation = {
  enable = true;
  # Explicit CPU alternative; omit to retain CUDA/large-v3-turbo:
  package = inputs.zd.packages.${pkgs.stdenv.hostPlatform.system}.cpu;
  # An existing, readable file owned/provisioned by the administrator/user:
  modelPath = "/var/lib/dictation/ggml-model.bin";
  sizing = {
    transcriptBytes = 4096;
    audioSamples = 640000;
    audioWindows = 4;
    windowMinSamples = 64000;
    pauseSamples = 16000;
    contextBytes = 128;
    deviceSlots = 4;
    workerStackBytes = 2097152;
    inferenceThreads = 2;
    controlClients = 4;
    clipboardSlots = 2;
    transfers = 2;
  };
};
```

An absolute **string** stays a host path, read by the service user; the module
does not create/chown/download that file. A Nix path or model derivation is
provisioned into the store. Do not put private data in Nix paths expecting the
store to keep it secret. Neither form creates a runtime download path. An
unreadable/incompatible model leaves the application failed, with no model or
fixture substitution and no microphone activity. GPU unavailability separately
allows upstream CPU fallback with a warning. Restart after repairing the file.

All twelve sizing options above have the same names as package arguments. Module
sizing is authoritative over the base package's sizing overrides. Changing it or
the embedded model path rebuilds Zig; no runtime heap, arena, configuration parser
or model-path command-line flag is introduced. The read-only
`services.dictation.finalPackage` is the installed, configured derivation.
`nix/storage.nix` shares package defaults and module metadata; the actual typed
layout and arithmetic validation remain Zig's responsibility.

Defaults, units, limits, multiplicities and allocation exceptions are in the
[runtime storage ledger](runtime.md#static-storage-and-allocation-audit). In
particular, each transcript needs session/worker/clipboard copies, while device,
control and reader tables have their own capacities. `audioSamples` now sizes
**each recycled window**, multiplied by `audioWindows`, not the whole session.
At least two slots are required: one may remain borrowed by superseded inference
while the others accept replacement capture. No second whole-session bank is used.
`pauseSamples <= windowMinSamples <= audioSamples` must hold; invalid combinations
fail Zig compilation before deployment. Backlog exhaustion remains an explicit
failure, not a recording timer or a promise of unlimited transcript storage.

Inspect the **installed executable**, not just Nix option values:

```sh
/run/current-system/sw/bin/dictation footprint
```

For the verified aarch64 build, defaults occupy **19,529,728 bytes** and the
configuration above **12,517,376 bytes**, aligned to 65,536. Use the current binary's
output for other settings: streaming adds multiple audio windows, a bounded prompt
and short-tail padding, so milestone-03 measurements no longer apply. Restart
identities/cancellation bookkeeping are included in the typed total as well. Totals
include alignment/padding and the worker stack. The conservative main-thread stack
budget is separately **16 KiB**, not compiler-certified. Native library/driver allocations
are excluded, as is the separately bounded **51,200-byte** Wayland pixel backing.
This is not a total RSS/VRAM limit. Module types reject out-of-range or incompatible
settings during evaluation; package compilation independently rejects invalid and
overflowing sizes before any service can run. Future storage inputs must be added
to the same package/module contract, typed layout and consumer checks.

## Shutdown and privacy boundaries

Stopping the session stops dictation, closes capture and releases its Wayland
connection. SIGTERM requests orderly worker abort/join; model initialization itself
is not cancellable. The unit permits 30 seconds for shutdown before systemd's
normal forced termination. No recording or transcript-history files are created.
Application diagnostics do not include dictated text.

An **external clipboard manager may retain copied text** independently. Conversely,
without one, stopping the service ends its clipboard ownership and the transcript
may no longer be pasteable. This is not a clipboard-history application or a
forensic-erasure guarantee.

**Locking alone does not cancel recording. Cancellation on suspend is not
promised.** Stop recording before locking/suspending if that is your intent.
There is no bespoke lock/suspend integration in v1.

## Separate verification

Fast checks and the native package's `checkPhase` remain **only Zig's standard
test suite**, with `doCheck` enabled. The following are separate named consumers:

```sh
# Public module evaluation, invalid settings, and built default/non-default footprint:
nix build .#cpu.passthru.tests.module-config --no-link -L

# Boot and exercise the installed user-service workflow (KVM):
nix build .#cpu.passthru.tests.session-vm --no-link -L

# Same assertions with explicit software CPU emulation, without /dev/kvm:
nix build .#cpu.passthru.tests.session-vm-tcg --no-link -L
```

The same names are exposed on `.#default.passthru.tests`. All explicitly select
the real CPU package for executable checks; none runs the CUDA package without
a GPU. They are **not** selected by a flake `checks` output or CI, and attaching
`passthru.tests` does not execute them during normal package builds.

`module-config` needs a native Linux builder for the selected supported system
(aarch64 or x86_64), Zig/toolchain dependencies and Nix provisioning access/cache.
It tests enabled/disabled installation, user-unit relationships, default model,
package/local-path overrides, all sizing values in built binaries, and invalid,
incompatible or overflowing configuration. It does not boot a service.

`session-vm` needs a Linux NixOS-test builder (`nixos-test` and `kvm` system
features), a usable `/dev/kvm`, QEMU, roughly 2 GiB guest RAM plus host/build
headroom, and space for a NixOS closure. `session-vm-tcg` removes the KVM
requirement and forces much slower software emulation (Cortex-A72 on aarch64).
The driver allows a longer boot handshake. In the TCG variant only, its test
transport waits for real console character devices rather than delayed udev
device-unit tags; the installed dictation and PipeWire units are unchanged.
Merely advertising a Nix system feature does not create its device. Dependencies
and tiny.en are provisioned by Nix before execution; the guest performs no model
download. The VM
uses a normal user, a desktop-owned generic target, **real PipeWire/WirePlumber**,
a virtual input fed pinned upstream JFK speech, real CPU whisper model/state
initialization, and headless Sway with **native indicator and clipboard**.
Both VM variants explicitly preload `nix/test-inference.c` into the test service:
it substitutes only the three decode/result functions, requires at least one
second of finite non-silent PCM, and returns labelled fixed text. It does not
replace model loading, capture or Wayland. This is **not speech recognition
verification**; the separate `capture-inference` consumer runs real CPU decoding.
The adapter is neither installed with the package nor enabled by the exported
module. It checks environment
skipping/import, bad-model refusal, configured footprint, absent-default refusal,
visible pixel changes, independent clipboard retrieval and shutdown during capture.
It uses no Home Manager, UWSM or Hyprland integration. Screenshots and the driver
log are test artifacts, not application recording/history features.

Creating/evaluating these derivations is distinct from executing them successfully.
Target RTX 3090 execution, physical microphone quality, recognition latency and
real-desktop focus/click-through acceptance remain milestone 09.

### Recorded milestone-03 verification

Executed on an **aarch64-linux** builder with Zig **0.17.1**:

- Nix/Zig formatting and both standard Zig test invocations passed: **12 tests**.
- Default/CPU package builds, `module-config`, and the five existing native/sizing
  consumers (`native-smoke`, `capture-inference`, `model-failure`,
  `backend-required`, `sizing`) succeeded. Unchanged native derivations reused
  their successful build results; their real CPU recognition evidence is recorded
  in [runtime.md](runtime.md#recorded-milestone-02-verification).
- **`session-vm-tcg` executed successfully**, not merely evaluated. Its test script
  took about 640 seconds without `/dev/kvm`. It verified the installed executable
  running as UID 1000, environment skip/import, missing model and default-source
  refusal, all configured sizing values, real virtual-input capture, visible
  indicator pixels, final-only native clipboard delivery of the adapter's fixed
  text, and clean session shutdown releasing capture, clipboard and control.
  The result includes `screenshots/recording.png`.
- The KVM `session-vm` derivation was successfully created, but **not executed**
  here because `/dev/kvm` is unavailable. An earlier real-decoding TCG attempt did
  not finish within 600 seconds; it is not successful VM recognition evidence.
  The checked-in VM explicitly uses the decoder adapter described above.

Self-review against milestone 02 covered standards/allocation and ticket-03
acceptance separately, with no remaining ticket-03 findings. No independent
reviewer was available. Physical microphone, NVIDIA execution and target-desktop
quality/latency/focus/click-through validation remain milestone 09.

### Runtime allocation review

This slice changes no production Zig or C runtime code. The test-only decoder
interposer is outside the package fileset and has no production linkage. The unit
executes the existing
`dictation daemon` entry point directly, without a shell wrapper, new runtime
arguments, a configuration-file parser or an environment-based sizing path.
Model paths and capacities still become build-time `src/options.zig` constants;
the built program computes and reports its actual `Storage` layout. The existing
startup, toggle, signal/shutdown, native ownership and allocation findings in
[runtime.md](runtime.md#static-storage-and-allocation-audit) still apply. Nix,
systemd and test-driver allocations are not application storage hidden behind a
runtime shim. This review is separate from the standard Zig test suite.
