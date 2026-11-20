# Use a resident service with native integrations

Use one resident Zig user service with a loaded whisper.cpp model.
Use direct PipeWire capture and native Wayland integration for the indicator and clipboard.
A small toggle client lets the desktop shortcut launcher control the service.
The client does not need a compositor-specific API.

This choice favors low runtime overhead and model reuse.
A chain of recorder, transcription and clipboard utilities has a simpler initial implementation.
The resident service instead owns event handling, cancellation, buffer ownership and clipboard requests.

A small helper program is still acceptable if it makes a specific integration much simpler.
