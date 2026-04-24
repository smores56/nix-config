{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      nixpkgs,
      home-manager,
      ...
    }:
    let
      pkgsForSystem =
        system:
        import nixpkgs {
          inherit system;
          config = {
            allowUnfree = true;
          };
        };

      mkHomeConfiguration =
        args:
        home-manager.lib.homeManagerConfiguration rec {
          extraSpecialArgs = (
            rec {
              system = args.system or "x86_64-linux";
              isLinux = system == "x86_64-linux";
              polarity = args.polarity or "dark";
              displayManager = args.displayManager or null;
            }
            // args
          );
          pkgs = pkgsForSystem extraSpecialArgs.system;
          modules = [
            ./modules/home.nix
          ];
        };

      mkNixosConfiguration =
        args:
        nixpkgs.lib.nixosSystem {
          specialArgs = args;
          modules = [
            ./modules/host.nix
          ];
        };
    in
    {
      homeConfigurations = {
        "smores@smorestux" = mkHomeConfiguration {
          displayManager = "pop-os";
          helixTheme = "noctis_bordo";
        };
        "smores@smoresbook" = mkHomeConfiguration {
          displayManager = "pop-os";
          helixTheme = "kanagawa";
        };
        "smores@campfire" = mkHomeConfiguration {
          displayManager = null;
        };
        "smores@smortress" = mkHomeConfiguration {
          displayManager = "pop-os";
          helixTheme = "gruvbox";
        };
        "smores@smoresnet" = mkHomeConfiguration {
          displayManager = null;
          helixTheme = "gruvbox";
        };
        "smohr" = mkHomeConfiguration {
          displayManager = "osx";
          username = "smohr";
          homeDirectory = "/Users/smohr";
          system = "aarch64-darwin";
          helixTheme = "rose_pine_moon";
          terminalFontSize = 14;
        };
      };

      nixosConfigurations = {
        "campfire" = mkNixosConfiguration {
          hostname = "campfire";
          expose-ssh = true;
          display-manager = null;
        };
        "smorestux" = mkNixosConfiguration {
          hostname = "smorestux";
          expose-ssh = false;
          display-manager = "cosmic";
        };
      };
    };
}
