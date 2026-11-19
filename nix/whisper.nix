{
  lib,
  stdenv,
  cmake,
  ninja,
  whisper-cpp,
  cudaPackages_12_9,
  autoAddDriverRunpath,
  cudaSupport ? true,
}:
let
  cuda = cudaPackages_12_9;
  buildStdenv = if cudaSupport then cuda.backendStdenv else stdenv;
in
buildStdenv.mkDerivation {
  pname = "dictation-whisper";
  inherit (whisper-cpp) version src;
  nativeBuildInputs = [
    cmake
    ninja
  ]
  ++ lib.optionals cudaSupport [
    cuda.cuda_nvcc
    autoAddDriverRunpath
  ];
  buildInputs = lib.optionals cudaSupport [
    cuda.cuda_cudart
    cuda.libcublas
  ];
  # Upstream permits silent CPU fallback even when use_gpu is true. Require
  # successful GPU initialization; its existing empty-backend path fails load.
  postPatch = ''
    substituteInPlace src/whisper.cpp --replace-fail \
      'ggml_backend_t backend_gpu = whisper_backend_init_gpu(params);' \
      'ggml_backend_t backend_gpu = whisper_backend_init_gpu(params); if (params.use_gpu && !backend_gpu) return {};'
  '';
  cmakeFlags = [
    "-DBUILD_SHARED_LIBS=ON"
    "-DWHISPER_BUILD_TESTS=OFF"
    "-DWHISPER_BUILD_EXAMPLES=OFF"
    "-DGGML_NATIVE=OFF"
    "-DGGML_BACKEND_DL=OFF"
    "-DGGML_OPENMP=OFF"
    (lib.cmakeBool "GGML_CUDA" cudaSupport)
  ]
  ++ lib.optionals cudaSupport [ "-DCMAKE_CUDA_ARCHITECTURES=86" ];
  meta.license = lib.licenses.mit;
}
