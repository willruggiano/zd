# Voice dictation

Voice dictation converts spoken input into text for use in other applications.

## Language

**Dictation**:
Speech intended to become written text.
_Avoid_: Voice command

**Dictation session**:
Speech submitted together to produce a single transcript.
_Avoid_: Conversation (a session may contain only one reply within a conversation)

**Finalization**:
The period after recording stops and before the session's transcript is ready to copy.
_Avoid_: Recording (the microphone is no longer capturing this session)

**Restart**:
Starting a new dictation session while the previous session is finalizing. The previous session is discarded and its transcript must not replace the clipboard.
_Avoid_: Queue (a restart replaces a session rather than adding another behind it)

**Transcript**:
The written text produced from dictation.
_Avoid_: Recording (which refers to audio, not text)

**Dictation indicator**:
The visual cue showing whether dictation is recording, processing, or has just succeeded or failed.
_Avoid_: Transcript preview (the indicator does not display the transcript)
