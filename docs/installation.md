# NixOS graphical-session installation

The flake exports **`nixosModules.default`**.
Use this checkout or a published revision with this module as your `zd` input.
For a local checkout, an example input is
`git+file:///absolute/path/to/dictation?ref=next`.
Pin the revision in `flake.lock`.
Add the module to your existing NixOS configuration:

```nix
modules = [
  ./configuration.nix
  inputs.zd.nixosModules.default
  { services.dictation.enable = true; }
];
```

Rebuild the system with your normal procedure. Switch to the new configuration.
The module installs `dictation` in the system profile and adds a **systemd user
service**. It does not run the microphone daemon as root.
Bind `dictation toggle` in your existing shortcut launcher.
See [runtime behavior](runtime.md#run) for the recording workflow and limits.

## Desktop and driver prerequisites

- Use a compositor with **layer-shell and ext-data-control-v1** support.
  Stock GNOME/Mutter does not support these requirements.
  There is no compositor-specific fallback.
- Use a working Wayland session with its normal `XDG_RUNTIME_DIR`.
  This module does not require or enable Home Manager, UWSM or a Hyprland module
  or package.
- The default package uses **CUDA/large-v3-turbo**. Nix supplies these dependencies
  with pinned hashes. Install a compatible NVIDIA driver before use.
  Make its libraries available through `/run/opengl-driver/lib`.
  The module does not configure a GPU driver or select a compositor.

  The flake permits unfree CUDA toolkit dependencies.
  Application code has an MIT license.
- The module enables user PipeWire and its audio support.
  NixOS normally enables WirePlumber with PipeWire and makes it a wanted
  dependency of `pipewire.service`. The module does not install a separate
  launcher for the session manager.
  Do not configure system-wide PipeWire for this user service.

The desktop controls the session lifetime and environment. PipeWire supplies audio:

```text
desktop
  --owns--> graphical-session.target
              --starts/stops--> dictation.service
                                  --needs--> pipewire.service
```

See [the module](../nix/module.nix) for exact unit settings.
**Service ordering is not microphone readiness.**
Before recording, wait for the model-ready message.
See [runtime operation](runtime.md#run) for GPU readiness and fallback behavior.

## The desktop owns the session

`ConditionEnvironment` examines the **user manager's environment**.
The terminal or shortcut launcher's environment alone is not sufficient.
After the compositor socket is ready, import the applicable variables through
your existing desktop startup procedure.
Then activate the desktop's session target.

```sh
systemctl --user import-environment WAYLAND_DISPLAY
# Your desktop then starts its normal session target.
```

logind/PAM normally supplies `XDG_RUNTIME_DIR`.
The compositor must use the same user and runtime directory.
Import only the necessary variables, not the entire shell environment.
**A target start never imports environment variables.**

The generic target is not a compositor launcher or a session supervisor.
The desktop controls its lifetime.
In the pinned systemd, the target also has `RefuseManualStart=yes` and
`StopWhenUnneeded=yes`.

If your desktop does not already own the generic target, add a desktop-owned
target alongside the module:

```nix
systemd.user.targets.my-desktop = {
  bindsTo = [ "graphical-session.target" ];
  after = [ "graphical-session.target" ];
};
```

Use the desktop's lifecycle hooks to run these commands:

```sh
# Startup, after WAYLAND_DISPLAY is set and its socket is ready:
systemctl --user import-environment WAYLAND_DISPLAY
systemctl --user start my-desktop.target

# Logout/desktop teardown, before removing its environment:
systemctl --user stop my-desktop.target
systemctl --user unset-environment WAYLAND_DISPLAY
```

This example configures the existing session owner.
It is **not** an application helper or a replacement desktop manager.
If the desktop already owns a session target, do not add this target.
An active session target keeps its services active after logout.
User lingering alone does not represent a graphical session.
One dictation daemon serves each UID, not each simultaneous display.

After a module update during an active graphical session, run these commands.
Use them also if you enable the module during that session.

```sh
systemctl --user daemon-reload
systemctl --user import-environment WAYLAND_DISPLAY
systemctl --user restart dictation.service
journalctl --user -u dictation.service -b
```

If the required environment is missing, systemd skips the unit. The service does
not start successfully. An environment import does not retry a skipped unit.
Start or restart the unit, or start the next desktop session.
An invalid display or unsupported protocol causes a failure with sanitized
application diagnostics.

To stop only dictation, use `systemctl --user stop dictation.service`.
A stop of the desktop target also affects its other services.
After a daemon-fatal failure, the unit retries according to its restart policy
and systemd start limits.
Before a retry, restore the dependency or rebuild with larger capacities.
If the unit reached a start limit, run `systemctl --user reset-failed dictation.service`.
Then restart the unit.

[Failure and recovery](runtime.md#failure-and-recovery) defines which errors
permit a new toggle and which require a restart.
It also describes the effect on clipboard ownership.

## Model and whole-program storage configuration

Options are under `services.dictation`.
`package` selects the base package.
`modelPath` defaults to the model that the package supplies.
For example:

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

An absolute **string** stays a host path. The service user reads that file.
The module does not create the file, change its owner or download it.
Nix copies a Nix path or model derivation into the store.

**Do not put private data in Nix paths. The store does not keep it secret.**
Neither form causes runtime downloads.

An unreadable or incompatible model causes application failure without microphone
activity. The daemon does not substitute another model or fixture output.
GPU unavailability separately permits upstream CPU fallback with a warning.
After you repair the model file, restart the daemon.

Sizing options use the same names as package arguments.
Module sizing overrides the base package's sizing values.
A change to sizing or the embedded model path rebuilds Zig.
It does not add a runtime heap, arena, configuration parser or model-path command-line flag.
The read-only `services.dictation.finalPackage` is the installed, configured derivation.

[nix/storage.nix](../nix/storage.nix) defines option descriptions, defaults and ranges.
See [runtime storage accounting](runtime.md#static-storage-and-allocation-audit)
for the relationship between configuration and memory use.
Module types reject out-of-range or incompatible settings during evaluation.
Zig compilation independently rejects invalid and overflowing layouts before installation.

Examine the **installed executable**, not only Nix option values:

```sh
/run/current-system/sw/bin/dictation footprint
```

The accounting guide explains the contents and exclusions of this total.
It is not a total RSS or VRAM limit.
See the [verification evidence](verification.md#recorded-milestone-08-verification)
for previous measurements, including the configuration example above.

## Shutdown

A desktop session stop also stops dictation. SIGTERM requests orderly teardown.
Systemd can force termination when the [unit's timeout](../nix/module.nix) expires.
See [runtime privacy and shutdown](runtime.md#privacy-and-shutdown) for microphone,
clipboard and data retention limits.
That section also describes lock and suspend behavior.

Use the [test catalog](testing.md#module-configuration) for module and
installed-session checks.
See [local evidence](verification.md#recorded-milestone-03-verification) for past
installation results.
