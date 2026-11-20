# Package defaults and module option metadata. Zig's Sizes.validate remains the
# authoritative compile-time safety check, including arithmetic overflow.
{
  transcriptBytes = {
    default = 1048576;
    min = 1;
    max = 67108864;
    description = "Bytes per transcript, worker result and clipboard slot.";
  };
  audioSamples = {
    default = 480000;
    min = 1;
    max = 9600000;
    description = "Maximum mono 16 kHz F32 samples per recycled window, four bytes each; not a session-duration cap.";
  };
  audioWindows = {
    default = 3;
    min = 2;
    max = 16;
    description = "Audio slots including the decoder borrow, queued windows and current capture window. Backlog exhaustion fails explicitly.";
  };
  windowMinSamples = {
    default = 48000;
    min = 1;
    max = 9600000;
    description = "Minimum window samples before a pause can seal it; at most audioSamples. Stop always seals a shorter tail.";
  };
  pauseSamples = {
    default = 8000;
    min = 1;
    max = 9600000;
    description = "Consecutive quiet samples for a pause boundary; at most windowMinSamples.";
  };
  contextBytes = {
    default = 256;
    min = 0;
    max = 4096;
    description = "Maximum prior current-session transcript bytes used as decoder prompt context, plus one NUL byte of worker storage. Zero disables context.";
  };
  deviceSlots = {
    default = 32;
    min = 1;
    max = 256;
    description = "PipeWire source records, each including a 256-byte name slot.";
  };
  workerStackBytes = {
    default = 8388608;
    min = 1048576;
    max = 67108864;
    multiple = 65536;
    description = "Bytes in the statically supplied inference worker stack; multiple of 65536.";
  };
  inferenceThreads = {
    default = 4;
    min = 1;
    max = 64;
    description = "Native decoder threads; does not multiply application job slots.";
  };
  controlClients = {
    default = 8;
    min = 1;
    max = 64;
    description = "Concurrent toggle-control peers.";
  };
  clipboardSlots = {
    default = 3;
    min = 2;
    max = 8;
    description = "Immutable clipboard transcript copies, including ownership and outstanding readers.";
  };
  transfers = {
    default = 8;
    min = 1;
    max = 64;
    description = "Concurrent clipboard readers.";
  };
}
