{
  runCommand,
  fetchzip,
  zig,
  pkg-config,
  wayland-scanner,
  wayland-protocols,
  wlr-protocols,
}:
let
  # v0.7.0 includes the Zig 0.17 update. The generator has no package dependencies.
  # Its allocator use belongs to this build tool, not the generated client.
  source = fetchzip {
    url = "https://codeberg.org/ifreund/zig-wayland/archive/fc7672f661874aa2015fc19a87ebabce787cf1c7.tar.gz";
    hash = "sha256-9rsYFmaWySpCWuNLYuSmgrMFT+QXbdJAY2uEKW48+I8=";
  };
in
runCommand "dictation-wayland-bindings"
  {
    nativeBuildInputs = [
      zig
      pkg-config
      wayland-scanner
    ];
  }
  ''
    export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
    zig build-exe ${source}/src/scanner.zig -OReleaseSafe -femit-bin=scanner
    mkdir -p "$out"
    # XDG XML supplies interface metadata referenced by layer-shell.
    # These versions match our implemented requests and listeners, not the newest XML versions.
    ./scanner -o "$out/wayland.zig" \
      -i "$(pkg-config --variable=pkgdatadir wayland-scanner)/wayland.xml" \
      -i ${wayland-protocols}/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml \
      -i ${wlr-protocols}/share/wlr-protocols/unstable/wlr-layer-shell-unstable-v1.xml \
      -i ${wayland-protocols}/share/wayland-protocols/staging/ext-data-control/ext-data-control-v1.xml \
      -g wl_compositor 4 -g wl_shm 1 -g wl_seat 1 -g wl_output 3 \
      -g zwlr_layer_shell_v1 1 -g ext_data_control_manager_v1 1
    install -Dm644 ${source}/LICENSE "$out/share/licenses/zig-wayland/LICENSE"
  ''
