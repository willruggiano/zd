{
  pkgs,
  flake,
  softwareEmulation ? false,
}:
let
  cpu = flake.packages.${pkgs.stdenv.hostPlatform.system}.cpu;
  # Explicit test-only substitution of three decoder-result functions. Real
  # whisper model loading (including bad paths) and state ownership stay intact.
  inferenceAdapter =
    pkgs.runCommand "dictation-test-inference"
      {
        nativeBuildInputs = [
          pkgs.stdenv.cc
          pkgs.pkg-config
        ];
        buildInputs = [ cpu.whisperLibrary ];
      }
      ''
        mkdir -p "$out/lib"
        $CC -std=c11 -Wall -Wextra -Werror -fPIC -shared \
          $(pkg-config --cflags-only-I whisper llama) ${./test-inference.c} \
          -o "$out/lib/libtest-inference.so"
      '';
  swayConfig = pkgs.writeText "dictation-test-sway.conf" ''
    output HEADLESS-1 mode 800x600
    output * bg #112233 solid_color
    seat seat0 fallback true
  '';
in
pkgs.testers.runNixOSTest {
  name = "dictation-graphical-session${pkgs.lib.optionalString softwareEmulation "-tcg"}";
  requiredFeatures.kvm = !softwareEmulation;
  nodes.machine = { ... }: {
    imports = [ flake.nixosModules.default ];
    # TCG coldplug can delay udev's device-unit tags beyond the harness timeout.
    # Only the test transport changes: wait for the real character devices rather
    # than their udev tags. The installed dictation/PipeWire units are untouched.
    systemd.services.backdoor = pkgs.lib.mkIf softwareEmulation {
      requires = pkgs.lib.mkForce [ ];
      after = pkgs.lib.mkForce [ ];
      preStart = ''
        until test -c /dev/hvc0 && test -c /dev/${
          if pkgs.stdenv.hostPlatform.isAarch64 then "ttyAMA0" else "ttyS0"
        }; do
          sleep 0.1
        done
      '';
    };
    virtualisation.qemu.forceAccel = pkgs.lib.mkForce (!softwareEmulation);
    virtualisation.qemu.options =
      pkgs.lib.optionals softwareEmulation [ "-machine accel=tcg" ]
      ++ pkgs.lib.optionals (softwareEmulation && pkgs.stdenv.hostPlatform.isAarch64) [
        "-cpu cortex-a72"
      ];
    virtualisation.memorySize = 2048;
    virtualisation.cores = 2;
    users.users.alice = {
      isNormalUser = true;
      uid = 1000;
    };
    services.dictation = {
      enable = true;
      package = cpu; # Real CPU/tiny.en model loading; explicitly adapted decoding.
      modelPath = "/home/alice/model.bin";
      sizing = import ./test-sizing.nix;
    };
    # This environment override exists ONLY in the test node, not the module.
    systemd.user.services.dictation.environment.LD_PRELOAD =
      "${inferenceAdapter}/lib/libtest-inference.so";
    # The containing desktop owns the generic target. No compositor-specific
    # module, Home Manager or UWSM imports/startup hooks are used in this test.
    systemd.user.targets.test-desktop = {
      bindsTo = [ "graphical-session.target" ];
      after = [ "graphical-session.target" ];
    };
    systemd.user.services.test-compositor = {
      environment = {
        WLR_BACKENDS = "headless";
        WLR_RENDERER = "pixman";
        WLR_LIBINPUT_NO_DEVICES = "1";
      };
      serviceConfig.ExecStart = "${pkgs.sway-unwrapped}/bin/sway --unsupported-gpu --config ${swayConfig}";
    };
    services.pipewire.extraConfig.pipewire."99-dictation-test" = {
      "context.modules" = [
        {
          name = "libpipewire-module-loopback";
          args = {
            "audio.position" = [ "MONO" ];
            "capture.props" = {
              "node.name" = "test-feed";
              "media.class" = "Audio/Sink";
            };
            "playback.props" = {
              "node.name" = "test-mic";
              "media.class" = "Audio/Source";
            };
          };
        }
      ];
    };
    environment.systemPackages = [
      pkgs.wl-clipboard
      pkgs.grim
      pkgs.jq
      pkgs.pipewire
      pkgs.wireplumber
      (pkgs.python3.withPackages (p: [ p.pillow ]))
    ];
  };
  testScript =
    { nodes, ... }:
    ''
      model = "${cpu.modelPath}"
      speech = "${pkgs.whisper-cpp.src}/samples/jfk.wav"
      binary = "${nodes.machine.services.dictation.finalPackage}/bin/dictation"
    ''
    + builtins.readFile ./session-vm.py;
}
