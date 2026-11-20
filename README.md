# Dictation

Local voice dictation for Wayland, using Zig and whisper.cpp:
toggle recording, speak, then toggle again to copy the transcript.

Status: the **short-reply path** implements native PipeWire capture, resident
whisper.cpp inference, a Wayland indicator and clipboard publication. Streaming
and graphical-session installation are still planned; target-GPU/desktop
validation remains pending. See [build, demo, storage and tests](docs/runtime.md)
or the explicitly simulated [fixture mode](docs/tracer.md).

- To understand the planned behavior, read [the design](docs/design.md).
- Before contributing, whether human or coding agent, read
  [CONTRIBUTING.md](CONTRIBUTING.md).
