# Dictation

Local voice dictation for Wayland, using Zig and whisper.cpp:
toggle recording, speak, then toggle again to copy the transcript.

Status: the packaged **fixture-only tracer** is implemented. It simulates capture
and inference, with a native Wayland indicator and clipboard; real dictation
is still planned. See [build, demo, storage and test instructions](docs/tracer.md).

- To understand the planned behavior, read [the design](docs/design.md).
- Before contributing, whether human or coding agent, read
  [CONTRIBUTING.md](CONTRIBUTING.md).
