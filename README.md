# Dictation

Local voice dictation for Wayland, using Zig and whisper.cpp:
toggle recording, speak, then toggle again to copy the transcript.

Status: **bounded streaming** implements native PipeWire capture, resident
whisper.cpp inference while recording, a Wayland indicator and final-only
clipboard publication. A NixOS module installs the graphical-session user service.
Asynchronous restart, reactive multi-monitor feedback and target-GPU/desktop
validation remain pending. See [installation](docs/installation.md),
[build, demo, storage and tests](docs/runtime.md), or the explicitly simulated
[fixture mode](docs/tracer.md).

- To understand the planned behavior, read [the design](docs/design.md).
- Before contributing, whether human or coding agent, read
  [CONTRIBUTING.md](CONTRIBUTING.md).
