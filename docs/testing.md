# Named integration checks

Use this page to select a test. Prepare its host as specified below.
Test source owns the scenarios and assertions. [CONTRIBUTING](../CONTRIBUTING.md#verification) owns
verification policy and fast-check commands. [Local evidence](verification.md)
records past runs. [Target validation](validation.md) records hardware acceptance.

## Invocation

Choose a name below. Run from the repository root:

```sh
name=capture-inference
nix build ".#cpu.passthru.tests.$name" --no-link -L
```

The same names are available on `.#default.passthru.tests`. These consumers select
CPU-capable packages. The default package uses CUDA, but these consumers do not run CUDA.
Nix supplies dependencies and models before test execution.

```text
native package build --checkPhase--> Zig tests
explicit nix build --passthru.tests--> selected consumer
actual target desktop --manual procedure--> hardware acceptance
```

Named consumers do not run during a normal package build or through automatic
CI or flake checks. Test artifacts can contain synthetic text and screenshots.
They are not application recording or history features.

## Native consumers

Use a native supported Linux builder. The desktop and audio harness starts private
Unix sockets, headless Sway, PipeWire and WirePlumber. It needs no host microphone,
desktop, GPU or `/dev/kvm`.

The [package test definitions](../nix/package.nix) select configurations.
The [native harness](../nix/smoke.nix) connects those packages to the drivers:

| Name | Test scope | Driver source |
| --- | --- | --- |
| `native-smoke` | Installed client and Wayland, with fixture audio and inference | [smoke.py](../nix/smoke.py) |
| `capture-inference` | Real capture and CPU recognition | [audio-smoke.py](../nix/audio-smoke.py) |
| `streaming` | Real multi-window CPU recognition | [audio-smoke.py](../nix/audio-smoke.py) |
| `restart` | Replacement capture during decode cancellation | [restart-smoke.py](../nix/restart-smoke.py) |
| `clipboard` | Concurrent native clipboard readers | [clipboard-smoke.py](../nix/clipboard-smoke.py) |
| `recovery-pipewire` | Session recovery and audio-server loss | [recovery-smoke.py](../nix/recovery-smoke.py) |
| `recovery-wayland` | Session recovery and compositor loss | [recovery-smoke.py](../nix/recovery-smoke.py) |
| `recovery-capacity` | Session recovery and device capacity | [recovery-smoke.py](../nix/recovery-smoke.py) |
| `indicator` | Multi-output pixels, protocols and resource release | [indicator-smoke.py](../nix/indicator-smoke.py) |
| `model-failure` | Startup with an invalid model | [model-failure.py](../nix/model-failure.py) |
| `backend-fallback` | GPU request with a CPU-only library | [audio-smoke.py](../nix/audio-smoke.py) |
| `sizing` | Installed footprint and configuration | [sizing.nix](../nix/sizing.nix) |

`restart`, `clipboard` and the recovery consumers use an explicit test-only
[decoder interposer](../nix/test-inference.c). Capture, model loading and Wayland
remain real. The adapter controls decode completion. It does not replace the
application. It is absent from production packages and module settings.

Independent real recognition coverage comes from `capture-inference` and
`streaming`. Synthetic input in `indicator` tests does not establish recognition
quality. Protocol flags and screenshots do not prove physical focus or pointer
behavior.

## Module configuration

`module-config` needs a native supported Linux builder and available Nix dependencies or cached results.
It evaluates the module and builds configured executables, but does not boot a
service. See [module-check.nix](../nix/module-check.nix) for assertions.

## Installed-session VMs

| Name | Host requirements |
| --- | --- |
| `session-vm` | Linux NixOS-test builder with `nixos-test` and `kvm` system features and a usable `/dev/kvm`. |
| `session-vm-tcg` | Software emulation without KVM. Much slower than KVM. |

Allow approximately 2 GiB of guest RAM. Allow additional memory for the host
and build. Reserve disk space for the NixOS closure.
A declared Nix system feature does not create its device.
VM setup and transport choices are in [session-vm.nix](../nix/session-vm.nix).
The installed workflow assertions are in [session-vm.py](../nix/session-vm.py).

The two variants use a normal user and a desktop-owned session target.
They use real audio servers, virtual speech input, real model loading and native Wayland effects.
The two variants explicitly substitute decoding with the test interposer. **VM success is
not speech-recognition or CUDA evidence.** The exported module does not enable
that substitution.
