{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    niri.url = "github:sodiboo/niri-flake";
    noctalia = {
      url = "github:noctalia-dev/noctalia-shell";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      nixpkgs,
      home-manager,
      niri,
      noctalia,
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
          overlays = [
            niri.overlays.niri
            noctalia.overlays.default
          ];
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
          modules =
            [
              ./modules/home.nix
            ]
            ++ (
              if (args.displayManager or null) == "niri" then
                [
                  niri.homeModules.niri
                  niri.homeModules.config
                  noctalia.homeModules.default
                ]
              else
                [ ]
            );
        };

      mkNixosConfiguration =
        args:
        nixpkgs.lib.nixosSystem {
          specialArgs = args;
          modules =
            [
              ./modules/host.nix
            ]
            ++ (
              if (args.display-manager or null) == "niri" then
                [
                  niri.nixosModules.niri
                ]
              else
                [ ]
            );
        };
    in
    {
      homeConfigurations = {
        "smores@smorestux" = mkHomeConfiguration {
          displayManager = "pop-os";
          helixTheme = "noctis_bordo";
        };
        "smores@smoresbook" = mkHomeConfiguration {
          displayManager = "niri";
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
        "smoresbook" = mkNixosConfiguration {
          hostname = "smoresbook";
          expose-ssh = false;
          display-manager = "niri";
        };
      };
    };
}
