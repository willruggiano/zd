# Stream audio internally without a recording-duration cutoff

Transcribe bounded audio windows while recording continues.
Keep committed text internal.
Publish the complete transcript only after the user stops and finalization succeeds.
The user rejected a timed cutoff. Recycle fixed audio storage instead of reserving storage for an entire session.

This design adds complexity at chunk boundaries and in buffer ownership.
Inference must keep pace with capture.
Use a default transcript capacity of 1 MiB.
Make that capacity configurable as part of the whole-program comptime storage layout.

If text or audio-backlog capacity is exhausted, fail visibly.
Do not silently truncate output, discard speech or increase storage at runtime.
A toggle during finalization discards that session and starts a new recording.
Background inference during recording does not change the toggle's normal stop meaning.
