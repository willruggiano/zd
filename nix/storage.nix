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
    description = "Mono 16 kHz F32 samples; four bytes each. Exhaustion fails the session.";
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
