{
  whisper-cpp,
  cudaPackages_12_9,
  cudaSupport ? true,
}:
whisper-cpp.override {
  inherit cudaSupport;
  cudaPackages = cudaPackages_12_9;
  withSDL = false;
  withFFmpegSupport = false;
}
