{
  description = "Static-storage Wayland dictation tracer";
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
      formatter = each (system: (import nixpkgs { inherit system; }).nixfmt);
      packages = each (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          default = pkgs.callPackage ./nix/package.nix { zig = zig-overlay.packages.${system}."0.17.1"; };
        }
      );
      devShells = each (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          default = pkgs.mkShell {
            inputsFrom = [ self.packages.${system}.default ];
            shellHook = self.packages.${system}.default.postPatch;
            packages = [ pkgs.nixfmt ];
          };
        }
      );
    };
}
