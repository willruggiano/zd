let
  storage = import ./storage.nix;
in
{
  lib,
  stdenv,
  callPackage,
  zig,
  pkg-config,
  wayland,
  wayland-scanner,
  wayland-protocols,
  wlr-protocols,
  pipewire,
  cudaSupport ? true,
  modelPath ? (callPackage ./models.nix { }).large-v3-turbo,
  whisperLibrary ? callPackage ./whisper.nix { inherit cudaSupport; },
  audioSamples ? storage.audioSamples.default,
  audioWindows ? storage.audioWindows.default,
  windowMinSamples ? storage.windowMinSamples.default,
  pauseSamples ? storage.pauseSamples.default,
  contextBytes ? storage.contextBytes.default,
  deviceSlots ? storage.deviceSlots.default,
  outputSlots ? storage.outputSlots.default,
  workerStackBytes ? storage.workerStackBytes.default,
  inferenceThreads ? storage.inferenceThreads.default,
  transcriptBytes ? storage.transcriptBytes.default,
  controlClients ? storage.controlClients.default,
  clipboardSlots ? storage.clipboardSlots.default,
  transfers ? storage.transfers.default,
}:
let
  # Nix paths are provisioned; absolute strings deliberately remain host paths.
  modelFile = if builtins.isPath modelPath then builtins.path { path = modelPath; } else modelPath;
in
assert lib.assertMsg (
  stdenv.buildPlatform == stdenv.hostPlatform
) "dictation currently supports native builds only";
stdenv.mkDerivation (finalAttrs: {
  pname = "dictation";
  version = "0.1.0";
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../src
      ../build.zig
    ];
  };
  nativeBuildInputs = [
    zig
    pkg-config
    wayland-scanner
  ];
  buildInputs = [
    wayland
    pipewire
    whisperLibrary
  ];
  dontConfigure = true;
  # PipeWire also advertises flags that zig translate-c cannot accept. Pass only
  # pkg-config's include-directory flags when generating bindings.
  postPatch = ''
    mkdir -p generated
    wayland-scanner client-header ${wlr-protocols}/share/wlr-protocols/unstable/wlr-layer-shell-unstable-v1.xml generated/layer.h
    wayland-scanner private-code ${wlr-protocols}/share/wlr-protocols/unstable/wlr-layer-shell-unstable-v1.xml generated/layer.c
    wayland-scanner client-header ${wayland-protocols}/share/wayland-protocols/staging/ext-data-control/ext-data-control-v1.xml generated/control.h
    wayland-scanner private-code ${wayland-protocols}/share/wayland-protocols/staging/ext-data-control/ext-data-control-v1.xml generated/control.c
    wayland-scanner private-code ${wayland-protocols}/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml generated/xdg.c
    export ZIG_GLOBAL_CACHE_DIR=$PWD/.zig-cache/global
    if [ ! -s generated/c.zig ] || [ src/interop.h -nt generated/c.zig ] || [ src/native.h -nt generated/c.zig ]; then
      zig translate-c -lc $(pkg-config --cflags-only-I wayland-client libpipewire-0.3 whisper llama) -I generated src/interop.h > generated/c.zig.tmp &&
      mv generated/c.zig.tmp generated/c.zig
    fi
    cat > src/options.zig <<'EOF'
    pub const transcript_bytes: usize = ${toString transcriptBytes};
    pub const control_clients: usize = ${toString controlClients};
    pub const clipboard_slots: usize = ${toString clipboardSlots};
    pub const transfers: usize = ${toString transfers};
    pub const audio_samples: usize = ${toString audioSamples};
    pub const audio_windows: usize = ${toString audioWindows};
    pub const window_min_samples: usize = ${toString windowMinSamples};
    pub const pause_samples: usize = ${toString pauseSamples};
    pub const context_bytes: usize = ${toString contextBytes};
    pub const output_slots: usize = ${toString outputSlots};
    pub const device_slots: usize = ${toString deviceSlots};
    pub const worker_stack_bytes: usize = ${toString workerStackBytes};
    pub const inference_threads: usize = ${toString inferenceThreads};
    pub const cuda: bool = ${lib.boolToString cudaSupport};
    pub const model_path: [:0]const u8 = ${builtins.toJSON (toString modelFile)};
    EOF
  '';
  # Use Nix's libc configuration and GNU target/interpreter: an older libc symbol
  # baseline from explicit-target Zig compilation can be incompatible with PipeWire.
  # CUDA shared objects need libcuda.so.1 from the host driver, not the sandbox.
  # Only shared-library unresolved symbols are permitted; direct application
  # symbols must resolve. CPU builds retain strict shared-library resolution.
  buildPhase = ''
    runHook preBuild
    export ZIG_GLOBAL_CACHE_DIR=$PWD/.zig-cache/global
    zig libc > generated/libc.conf
    # nixpkgs supplies ggml via llama.cpp; whisper.pc omits its library path.
    zig build-exe ${lib.optionalString cudaSupport "-fallow-shlib-undefined "}--libc generated/libc.conf -OReleaseSafe -lc $(pkg-config --cflags-only-I --libs wayland-client libpipewire-0.3 whisper llama) \
      -rpath ${
        lib.makeLibraryPath [
          wayland
          pipewire
          whisperLibrary
        ]
      } -rpath $(pkg-config --variable=libdir llama) -I generated \
        -target ${stdenv.hostPlatform.parsed.cpu.name}-linux-gnu \
        --dynamic-linker ${stdenv.cc.bintools.dynamicLinker} \
      generated/layer.c generated/control.c generated/xdg.c src/native.c \
      --dep c -Mroot=src/main.zig -Mc=generated/c.zig -femit-bin=dictation
    runHook postBuild
  '';
  doCheck = stdenv.buildPlatform.canExecute stdenv.hostPlatform;
  checkPhase = ''
    runHook preCheck
    zig test src/tests.zig
    runHook postCheck
  '';
  installPhase = ''
    runHook preInstall
    install -Dm755 dictation $out/bin/dictation
    runHook postInstall
  '';
  passthru = {
    inherit whisperLibrary modelPath;
    tests =
      let
        cpu = callPackage ./package.nix {
          inherit zig;
          cudaSupport = false;
          modelPath = (callPackage ./models.nix { }).tiny-en;
        };
        windowed = cpu.override {
          audioSamples = 160000;
          audioWindows = 8;
          windowMinSamples = 160000;
          contextBytes = 128;
        };
        recovery = cpu.override {
          audioSamples = 16000;
          audioWindows = 4;
          windowMinSamples = 16000;
          pauseSamples = 8000;
          deviceSlots = 2;
        };
        small = cpu.override {
          modelPath = "/nonexistent/dictation-test-model.bin";
          transcriptBytes = 64;
          controlClients = 2;
          clipboardSlots = 2;
          transfers = 1;
          audioSamples = 160;
          audioWindows = 2;
          windowMinSamples = 80;
          pauseSamples = 40;
          contextBytes = 16;
          deviceSlots = 2;
          outputSlots = 1;
          workerStackBytes = 1048576;
          inferenceThreads = 1;
        };
      in
      {
        indicator = callPackage ./smoke.nix {
          package = cpu.override { outputSlots = 2; };
          withCaptureTest = true;
          withIndicatorTest = true;
        };
        recovery-pipewire = callPackage ./smoke.nix {
          package = recovery;
          withCaptureTest = true;
          recoveryDisconnect = "pipewire";
        };
        recovery-wayland = callPackage ./smoke.nix {
          package = recovery;
          withCaptureTest = true;
          recoveryDisconnect = "wayland";
        };
        recovery-capacity = callPackage ./smoke.nix {
          package = recovery;
          withCaptureTest = true;
          recoveryDisconnect = "capacity";
        };
        clipboard = callPackage ./smoke.nix {
          package = cpu.override {
            audioSamples = 16000;
            audioWindows = 8;
            windowMinSamples = 16000;
            pauseSamples = 8000;
            transcriptBytes = 262145; # two 128 KiB results and their separator
            clipboardSlots = 2;
            transfers = 3;
          };
          withCaptureTest = true;
          withClipboardTest = true;
        };
        restart = callPackage ./smoke.nix {
          package = windowed;
          withCaptureTest = true;
          withRestartTest = true;
        };
        streaming = callPackage ./smoke.nix {
          package = windowed;
          withCaptureTest = true;
          withStreamingTest = true;
        };
        capture-inference = callPackage ./smoke.nix {
          package = cpu;
          withCaptureTest = true;
        };
        backend-fallback = callPackage ./smoke.nix {
          # Request a GPU from the real CPU-only library: startup/recognition
          # must continue with a sanitized warning, not a patched failure.
          package = cpu.override {
            cudaSupport = true;
            whisperLibrary = cpu.whisperLibrary;
          };
          withCaptureTest = true;
          expectGpuFallback = true;
        };
        model-failure = callPackage ./smoke.nix {
          package = small;
          withCaptureTest = true;
          expectModelFailure = true;
        };
        native-smoke = callPackage ./smoke.nix { package = cpu; };
        sizing = callPackage ./sizing.nix {
          package = cpu;
          inherit small;
        };
      };
  };
  meta = {
    description = "Native PipeWire and whisper.cpp Wayland dictation";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "dictation";
  };
})
