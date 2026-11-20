{
  description = "Static-storage Wayland dictation";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/d3b13ad75cc492690728f9307e443dec9ef9a20e";
  inputs.zig-overlay.url = "github:mitchellh/zig-overlay/6aad0084d405f9661050b305514ca1fe627b9919";
  outputs =
    {
      self,
      nixpkgs,
      zig-overlay,
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      each = nixpkgs.lib.genAttrs systems;
    in
    {
      nixosModules.default = { pkgs, ... }: {
        imports = [
          (import ./nix/module.nix {
            defaultPackage = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
          })
        ];
      };
      formatter = each (system: (import nixpkgs { inherit system; }).nixfmt);
      packages = each (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config = {
              allowUnfree = true;
              cudaCapabilities = [ "8.6" ];
            };
          };
          package =
            args:
            (pkgs.callPackage ./nix/package.nix args).overrideAttrs (old: {
              passthru = old.passthru // {
                tests = old.passthru.tests // {
                  module-config = import ./nix/module-check.nix {
                    inherit pkgs;
                    flake = self;
                  };
                  session-vm = import ./nix/session-vm.nix {
                    inherit pkgs;
                    flake = self;
                  };
                  session-vm-tcg = import ./nix/session-vm.nix {
                    inherit pkgs;
                    flake = self;
                    softwareEmulation = true;
                  };
                };
              };
            });
        in
        {
          cpu = package {
            zig = zig-overlay.packages.${system}."0.17.1";
            cudaSupport = false;
            modelPath = (pkgs.callPackage ./nix/models.nix { }).tiny-en;
          };
          default = package { zig = zig-overlay.packages.${system}."0.17.1"; };
        }
      );
      devShells = each (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config = {
              allowUnfree = true;
              cudaCapabilities = [ "8.6" ];
            };
          };
        in
        {
          default =
            let
              zig = zig-overlay.packages.${system}."0.17.1";
              package = self.packages.${system}.cpu.override { modelPath = "/var/lib/dictation/model.bin"; };
            in
            pkgs.mkShell {
              inputsFrom = [ package ];
              shellHook = package.postPatch + ''
                cat <<'EOF'
                Welcome to the `zd` development shell.

                ${zig}
                  lib/std/             standard-library source, doc comments and tests
                  doc/langref.html     bundled language reference and style guide
                  lib/compiler/std-docs.zig  implementation of zig std
                EOF
              '';
              packages = [
                pkgs.gh
                pkgs.gh-stack
                pkgs.gitMinimal
                pkgs.nixfmt
              ];
            };
        }
      );
    };
}
