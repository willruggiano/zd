{ pkgs, flake }:
let
  inherit (pkgs) lib;
  system = pkgs.stdenv.hostPlatform.system;
  evaluate =
    settings:
    (flake.inputs.nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        flake.nixosModules.default
        {
          system.stateVersion = "26.11";
          services.dictation = settings;
        }
      ];
    }).config;
  enabled = evaluate { enable = true; };
  disabled = evaluate { };
  unit = enabled.systemd.user.services.dictation;
  small = evaluate {
    enable = true;
    package = flake.packages.${system}.cpu;
    modelPath = "/home/alice/model.bin";
    sizing = import ./test-sizing.nix;
  };
  installed = small.services.dictation.finalPackage;
  invalid = [
    { sizing.transcriptBytes = 0; }
    { sizing.controlClients = -1; }
    { sizing.clipboardSlots = 1; }
    { sizing.transfers = 0; }
    { sizing.audioSamples = 9223372036854775807; }
    { sizing.audioWindows = 1; }
    { sizing.windowMinSamples = 0; }
    { sizing.pauseSamples = 0; }
    { sizing.contextBytes = 4097; }
    { sizing.deviceSlots = 257; }
    { sizing.outputSlots = 0; }
    { sizing.outputSlots = 65; }
    { sizing.workerStackBytes = 2097153; }
    { sizing.inferenceThreads = 0; }
    { modelPath = "relative-model.bin"; }
  ];
  rejected =
    settings:
    !(builtins.tryEval
      (evaluate ({ enable = true; } // settings)).services.dictation.finalPackage.drvPath
    ).success;
in
assert unit.wantedBy == [ "graphical-session.target" ];
assert unit.partOf == [ "graphical-session.target" ];
assert unit.wants == [ "pipewire.service" ];
assert unit.after == [ "pipewire.service" ];
assert unit.unitConfig.ConditionEnvironment == "WAYLAND_DISPLAY";
assert unit.serviceConfig.Restart == "on-failure";
assert unit.serviceConfig.RestartSec == 2;
assert enabled.services.pipewire.enable && enabled.services.pipewire.audio.enable;
assert enabled.services.pipewire.wireplumber.enable;
assert !(enabled.systemd.services ? dictation);
assert !(disabled.systemd.user.services ? dictation);
assert
  !(lib.any (
    p: p.outPath == enabled.services.dictation.finalPackage.outPath
  ) disabled.environment.systemPackages);
assert enabled.services.dictation.modelPath == flake.packages.${system}.default.modelPath;
assert enabled.services.dictation.finalPackage.doCheck && installed.doCheck;
assert lib.all rejected invalid;
assert
  small.systemd.user.services.dictation.serviceConfig.ExecStart
  == "${installed}/bin/dictation daemon";
assert lib.any (p: p.outPath == installed.outPath) small.environment.systemPackages;
pkgs.runCommand "dictation-module-config" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  mkdir "$out"
  ${flake.packages.${system}.cpu}/bin/dictation footprint > "$out/default"
  ${installed}/bin/dictation footprint > "$out/configured"
  python3 - "$out" <<'PYTHON'
  from pathlib import Path
  import sys
  def read(name):
      return {k: int(v) for k, v in (line.split('=') for line in (Path(sys.argv[1]) / name).read_text().splitlines())}
  default, configured = read('default'), read('configured')
  expected = dict(transcript_bytes=4096, control_clients=4, clipboard_slots=2,
                  transfers=2, audio_samples=640000, audio_windows=4,
                  window_min_samples=64000, pause_samples=16000, context_bytes=128, device_slots=4, output_slots=3,
                  worker_stack_bytes=2097152, inference_threads=2)
  assert all(configured[k] == v for k, v in expected.items())
  expected_default = dict(transcript_bytes=1048576, control_clients=8, clipboard_slots=3,
                          transfers=8, audio_samples=480000, audio_windows=3,
                          window_min_samples=48000, pause_samples=8000, context_bytes=256, device_slots=32, output_slots=8,
                          worker_stack_bytes=8388608, inference_threads=4)
  assert all(default[k] == v for k, v in expected_default.items())
  assert configured['static_bytes'] != default['static_bytes']
  assert configured['static_bytes'] % configured['alignment'] == 0
  assert configured['session_bytes'] > 640000 * 4 * 4
  assert configured['worker_bytes'] > 2097152
  assert configured['wayland_backing_bytes'] == 614400
  assert configured['replacement_audio_windows'] == 3
  assert default['replacement_audio_windows'] == 2
  assert configured['retained_inference_windows'] == default['retained_inference_windows'] == 1
  PYTHON
''
