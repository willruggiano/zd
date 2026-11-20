{
  lib,
  runCommand,
  sway-unwrapped,
  wl-clipboard,
  python3,
  dbus,
  package,
  pipewire,
  wireplumber,
  whisper-cpp,
  withCaptureTest ? false,
  withStreamingTest ? false,
  expectModelFailure ? false,
}:
runCommand
  (
    if expectModelFailure then
      "dictation-model-failure"
    else if withStreamingTest then
      "dictation-native-streaming"
    else if withCaptureTest then
      "dictation-native-capture-inference"
    else
      "dictation-native-fixture-smoke"
  )
  {
    nativeBuildInputs = [
      sway-unwrapped
      wl-clipboard
      python3
      dbus
    ]
    ++ lib.optionals withCaptureTest [
      pipewire
      wireplumber
    ];
    # Private headless compositor. Capture variant adds virtual PipeWire and CPU inference; never host hardware.
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
    audio_server=
    policy=
    bus=
    daemon=
    trap 'status=$?; if [ $status -ne 0 ]; then cat *.log; fi; kill ''${daemon:-} $compositor ''${audio_server:-} ''${policy:-} ''${bus:-} 2>/dev/null || true' EXIT
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
    ${lib.optionalString withCaptureTest ''
      dbus-daemon --config-file=${dbus}/share/dbus-1/session.conf --fork --print-address=1 --print-pid=1 > dbus-info
      export DBUS_SESSION_BUS_ADDRESS=$(head -1 dbus-info)
      bus=$(tail -1 dbus-info)
      mkdir -p config/pipewire.conf.d
      cp ${pipewire}/share/pipewire/pipewire.conf config/
      cat > config/pipewire.conf.d/sources.conf <<'PW'
      context.modules = [
        { name = libpipewire-module-loopback args = {
          audio.position = [ MONO ]
          capture.props = { node.name = test-feed-a media.class = Audio/Sink }
          playback.props = { node.name = test-mic-a media.class = Audio/Source }
        } }
        { name = libpipewire-module-loopback args = {
          audio.position = [ MONO ]
          capture.props = { node.name = test-feed-b media.class = Audio/Sink }
          playback.props = { node.name = test-mic-b media.class = Audio/Source }
        } }
      ]
      PW
      PIPEWIRE_CONFIG_DIR=$PWD/config pipewire >pipewire.log 2>&1 &
      audio_server=$!
      for i in $(seq 1 200); do test ! -S "$XDG_RUNTIME_DIR/pipewire-0" || break; sleep .05; done
      wireplumber >wireplumber.log 2>&1 &
      policy=$!
    ''}
    if ${package}/bin/dictation toggle 2>missing.log; then exit 1; fi
    grep -q DaemonUnavailable missing.log
    printf 'Previous clipboard' | wl-copy
    ${package}/bin/dictation daemon ${
      lib.optionalString (!withCaptureTest) "--fixture"
    } >daemon.log 2>&1 &
    daemon=$!
    for i in $(seq 1 200); do
      if grep -q 'native Wayland ready' daemon.log; then break; fi
      kill -0 "$daemon" || { cat daemon.log; exit 1; }
      sleep .05
    done
    ${lib.optionalString (!withCaptureTest) "grep -q 'FIXTURE audio/inference' daemon.log"}
    ${package}/bin/dictation footprint > footprint
    ${
      if expectModelFailure then
        "python3 ${./model-failure.py} ${package}/bin/dictation"
      else if withCaptureTest then
        "python3 ${./audio-smoke.py} ${package}/bin/dictation ${whisper-cpp.src}/samples/jfk.wav ${lib.optionalString withStreamingTest "--streaming"}"
      else
        "python3 ${./smoke.py} ${package}/bin/dictation"
    }
    kill -TERM "$daemon"
    wait "$daemon"
    daemon=
    if ${package}/bin/dictation toggle 2>stopped.log; then exit 1; fi
    grep -q DaemonUnavailable stopped.log
    ! grep -q 'Fixture dictation result' daemon.log
    mkdir "$out"
    cp footprint daemon.log "$out/"
  ''
