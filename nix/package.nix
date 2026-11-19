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
  transcriptBytes ? 1048576,
  controlClients ? 8,
  clipboardSlots ? 3,
  transfers ? 8,
}:
assert lib.assertMsg (
  stdenv.buildPlatform == stdenv.hostPlatform
) "dictation tracer currently supports native builds only";
stdenv.mkDerivation (finalAttrs: {
  pname = "dictation-tracer";
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
  buildInputs = [ wayland ];
  dontConfigure = true;
  postPatch = ''
    mkdir -p generated
    wayland-scanner client-header ${wlr-protocols}/share/wlr-protocols/unstable/wlr-layer-shell-unstable-v1.xml generated/layer.h
    wayland-scanner private-code ${wlr-protocols}/share/wlr-protocols/unstable/wlr-layer-shell-unstable-v1.xml generated/layer.c
    wayland-scanner client-header ${wayland-protocols}/share/wayland-protocols/staging/ext-data-control/ext-data-control-v1.xml generated/control.h
    wayland-scanner private-code ${wayland-protocols}/share/wayland-protocols/staging/ext-data-control/ext-data-control-v1.xml generated/control.c
    wayland-scanner private-code ${wayland-protocols}/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml generated/xdg.c
    export ZIG_GLOBAL_CACHE_DIR=$PWD/.zig-cache/global
    if [ ! -s generated/c.zig ] || [ src/interop.h -nt generated/c.zig ]; then
      zig translate-c -lc $(pkg-config --cflags wayland-client) -I generated src/interop.h > generated/c.zig.tmp
      mv generated/c.zig.tmp generated/c.zig
    fi
    cat > src/options.zig <<'EOF'
    pub const transcript_bytes: usize = ${toString transcriptBytes};
    pub const control_clients: usize = ${toString controlClients};
    pub const clipboard_slots: usize = ${toString clipboardSlots};
    pub const transfers: usize = ${toString transfers};
    EOF
  '';
  buildPhase = ''
    runHook preBuild
    export ZIG_GLOBAL_CACHE_DIR=$PWD/.zig-cache/global
    zig build-exe -OReleaseSafe -lc $(pkg-config --cflags --libs wayland-client) \
      -rpath ${lib.getLib wayland}/lib -I generated \
        -target ${stdenv.hostPlatform.parsed.cpu.name}-linux-gnu \
        --dynamic-linker ${stdenv.cc.bintools.dynamicLinker} \
      generated/layer.c generated/control.c generated/xdg.c \
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
  passthru.tests = {
    native-smoke = callPackage ./smoke.nix { package = finalAttrs.finalPackage; };
    sizing = callPackage ./sizing.nix {
      package = finalAttrs.finalPackage;
      small = callPackage ./package.nix {
        inherit zig;
        transcriptBytes = 64;
        controlClients = 2;
        clipboardSlots = 2;
        transfers = 1;
      };
    };
  };
  meta = {
    description = "Explicit fixture-only native Wayland dictation tracer";
    platforms = lib.platforms.linux;
    mainProgram = "dictation";
  };
})
