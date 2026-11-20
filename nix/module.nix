{ defaultPackage }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.dictation;
  storage = import ./storage.nix;
in
{
  options.services.dictation = {
    enable = lib.mkEnableOption "local Wayland dictation with the graphical session";
    package = lib.mkOption {
      type = lib.types.package;
      default = defaultPackage;
      defaultText = lib.literalExpression "inputs.zd.packages.${pkgs.stdenv.hostPlatform.system}.default";
      description = "Base dictation package with modelPath and sizing overrides; defaults to CUDA/large-v3-turbo. Select the flake's cpu package explicitly for CPU inference.";
    };
    modelPath = lib.mkOption {
      type = lib.types.path;
      default = cfg.package.modelPath;
      defaultText = lib.literalExpression "config.services.dictation.package.modelPath";
      description = "Model derivation/Nix path provisioned at build time, or an absolute string naming an existing host file. The service never downloads a model.";
    };
    sizing = lib.mapAttrs (
      _: spec:
      lib.mkOption {
        type = lib.types.addCheck (lib.types.ints.between spec.min spec.max) (
          value: lib.mod value (spec.multiple or 1) == 0
        );
        inherit (spec) default description;
      }
    ) storage;
    finalPackage = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = cfg.package.override (cfg.sizing // { inherit (cfg) modelPath; });
      defaultText = lib.literalExpression "config.services.dictation.package.override (...)";
      description = "Installed executable with the configured build-time model path and complete sizing inputs. Run its dictation footprint command to inspect the compiled layout.";
    };
  };
  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.finalPackage ];
    services.pipewire.enable = true;
    services.pipewire.audio.enable = true;
    systemd.user.services.dictation = {
      description = "Local voice dictation";
      wantedBy = [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];
      wants = [ "pipewire.service" ];
      after = [ "pipewire.service" ];
      unitConfig.ConditionEnvironment = "WAYLAND_DISPLAY";
      serviceConfig = {
        Type = "exec";
        ExecStart = "${cfg.finalPackage}/bin/dictation daemon";
        Restart = "on-failure";
        RestartSec = 2;
        TimeoutStopSec = 30;
      };
    };
  };
}
