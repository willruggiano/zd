# Shared consumer configuration for the module check and installed-session VM.
{
  transcriptBytes = 4096;
  controlClients = 4;
  clipboardSlots = 2;
  transfers = 2;
  audioSamples = 640000;
  audioWindows = 4;
  windowMinSamples = 64000;
  pauseSamples = 16000;
  contextBytes = 128;
  deviceSlots = 4;
  workerStackBytes = 2097152;
  inferenceThreads = 2;
}
