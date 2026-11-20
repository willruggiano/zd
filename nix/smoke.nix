{
  runCommand,
  sway-unwrapped,
  wl-clipboard,
  python3,
  dbus,
  package,
}:
runCommand "dictation-native-fixture-smoke"
  {
    nativeBuildInputs = [
      sway-unwrapped
      wl-clipboard
      python3
      dbus
    ];
    # A private headless compositor; no GPU, host desktop, audio, model or VM.
  }
  ''
    export HOME=$TMPDIR/home
    export XDG_RUNTIME_DIR=$TMPDIR/runtime
    mkdir -m 700 -p "$HOME" "$XDG_RUNTIME_DIR"
    export WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1
    cat > sway.conf <<'CONFIG'
    output HEADLESS-1 mode 800x600
    seat seat0 fallback true
    CONFIG
    sway --unsupported-gpu --config "$PWD/sway.conf" >sway.log 2>&1 &
    compositor=$!
    daemon=
    trap 'status=$?; if [ $status -ne 0 ]; then cat *.log; fi; kill ''${daemon:-} $compositor 2>/dev/null || true' EXIT
    socket=
    for i in $(seq 1 200); do
      for candidate in "$XDG_RUNTIME_DIR"/wayland-*; do
        if [ -S "$candidate" ]; then socket=$candidate; break; fi
      done
      if [ -n "$socket" ]; then break; fi
      kill -0 "$compositor" || { cat sway.log; exit 1; }
      sleep .05
    done
    export WAYLAND_DISPLAY=$(basename "$socket")
    test -S "$socket" || { cat sway.log; exit 1; }
    if ${package}/bin/dictation toggle 2>missing.log; then exit 1; fi
    grep -q DaemonUnavailable missing.log
    printf 'Previous clipboard' | wl-copy
    ${package}/bin/dictation daemon --fixture >daemon.log 2>&1 &
    daemon=$!
    for i in $(seq 1 200); do
      if grep -q 'native Wayland ready' daemon.log; then break; fi
      kill -0 "$daemon" || { cat daemon.log; exit 1; }
      sleep .05
    done
    grep -q 'FIXTURE audio/inference' daemon.log
    ${package}/bin/dictation footprint > footprint
    python3 ${./smoke.py} ${package}/bin/dictation
    kill -TERM "$daemon"
    wait "$daemon"
    daemon=
    if ${package}/bin/dictation toggle 2>stopped.log; then exit 1; fi
    grep -q DaemonUnavailable stopped.log
    ! grep -q 'Fixture dictation result' daemon.log
    mkdir "$out"
    cp footprint daemon.log "$out/"
  ''
