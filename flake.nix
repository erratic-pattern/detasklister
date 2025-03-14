{
  description = "Remove tasklist blocks from GitHub issues";

  outputs =
    inputs@{
      self,
      nixpkgs,
      alejandra,
    }:
    let
      inherit (nixpkgs) lib;
      name = "detasklister";
      forAllSystems = lib.genAttrs (lib.platforms.all);
    in
    rec {
      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = "${defaultPackage.${system}.outPath}/bin/${name}";
        };
      });

      packages = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          ${name} = pkgs.writeShellApplication {
            inherit name;
            runtimeInputs = with pkgs; [
              perl
              gh
            ];
            text = ''
              exec perl -- ${./detasklister.pl} "$@"
            '';
          };
        }
      );

      defaultPackage = forAllSystems (system: packages.${system}.detasklister);

      devShell = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        pkgs.mkShell {
          name = "${name}-shell";
          packages = with pkgs; [
            perl
            gh
          ];
        }
      );

      formatter = forAllSystems (system: alejandra.defaultPackage.${system});
    };

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";

    alejandra.url = "github:kamadorueda/alejandra/3.1.0";
    alejandra.inputs.nixpkgs.follows = "nixpkgs";
  };
}
