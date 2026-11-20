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
`dictation toggle` in your existing shortcut launcher; see
[runtime behavior](runtime.md#run) for the recording workflow and limitations.

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

The session supplies lifetime and environment; PipeWire supplies audio:

```text
desktop
  --owns--> graphical-session.target
              --starts/stops--> dictation.service
                                  --needs--> pipewire.service
```

See [the module](../nix/module.nix) for exact unit settings.
**Service ordering is not microphone readiness.** Wait for the model-ready
message before recording. GPU readiness and fallback are explained in
[runtime operation](runtime.md#run).

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

For daemon-fatal failures, the unit retries under its configured restart policy
and systemd start limits. Restore the dependency (or rebuild
with larger capacities) before retrying. If a start limit was reached, run
`systemctl --user reset-failed dictation.service`, then restart it.
[Failure and recovery](runtime.md#failure-and-recovery) defines which errors
permit a fresh toggle, which require restart, and what happens to clipboard
ownership.

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
    outputSlots = 3;
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

Sizing options use the same names as package arguments. Module sizing overrides
the base package's sizing values. Changing sizing or
the embedded model path rebuilds Zig; no runtime heap, arena, configuration parser
or model-path command-line flag is introduced. The read-only
`services.dictation.finalPackage` is the installed, configured derivation.
[nix/storage.nix](../nix/storage.nix) defines option descriptions, defaults and
ranges. Use [runtime storage accounting](runtime.md#static-storage-and-allocation-audit)
for the relationships between configuration and memory use. Module types
reject out-of-range or incompatible settings during evaluation; Zig compilation
independently rejects invalid and overflowing layouts before deployment.

Inspect the **installed executable**, not just Nix option values:

```sh
/run/current-system/sw/bin/dictation footprint
```

The accounting guide explains what this total includes and excludes; it is not a total
RSS/VRAM limit. Previously measured layouts, including the example above, live
in the [verification evidence](verification.md#recorded-milestone-08-verification).

## Shutdown

Stopping the desktop session stops dictation. SIGTERM requests orderly teardown.
Systemd can force termination when the [unit's timeout](../nix/module.nix) expires. See
[runtime privacy and shutdown](runtime.md#privacy-and-shutdown) for microphone,
clipboard, lock/suspend and retention boundaries.

For module and installed-session checks, use the
[test catalog](testing.md#module-configuration); past installation results are in
[local evidence](verification.md#recorded-milestone-03-verification).
