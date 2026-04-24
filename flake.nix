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

      flakeModules = {
        home.niri = [
          niri.homeModules.niri
          niri.homeModules.config
          noctalia.homeModules.default
        ];
        nixos.niri = [ niri.nixosModules.niri ];
      };

      mkHome =
        args:
        let
          system = args.system or "x86_64-linux";
          dm = args.displayManager or null;
        in
        home-manager.lib.homeManagerConfiguration {
          pkgs = pkgsForSystem system;
          extraSpecialArgs = {
            displayManager = dm;
          };
          modules =
            [
              ./modules/home.nix
              {
                dotfiles = {
                  displayManager = dm;
                  polarity = args.polarity or "dark";
                  helixTheme = args.helixTheme or null;
                  terminalFontSize = args.terminalFontSize or 12;
                };
                home.username = args.username or "smores";
                home.homeDirectory = args.homeDirectory or "/home/${args.username or "smores"}";
              }
            ]
            ++ (if dm != null then (flakeModules.home.${dm} or [ ]) else [ ]);
        };

      mkNixos =
        args:
        let
          dm = args.displayManager or null;
        in
        nixpkgs.lib.nixosSystem {
          specialArgs = {
            displayManager = dm;
            exposeSsh = args.exposeSsh or false;
          };
          modules =
            [
              ./modules/host.nix
              ./hosts/${args.hostname}/hardware.nix
              {
                networking.hostName = args.hostname;
                dotfiles = {
                  displayManager = dm;
                  exposeSsh = args.exposeSsh or false;
                };
              }
            ]
            ++ (if dm != null then (flakeModules.nixos.${dm} or [ ]) else [ ]);
        };
    in
    {
      homeConfigurations = {
        "smores@smorestux" = mkHome {
          displayManager = "pop-os";
          helixTheme = "noctis_bordo";
        };
        "smores@smoresbook" = mkHome {
          displayManager = "niri";
          helixTheme = "kanagawa";
        };
        "smores@campfire" = mkHome { };
        "smores@smortress" = mkHome {
          displayManager = "pop-os";
          helixTheme = "gruvbox";
        };
        "smores@smoresnet" = mkHome {
          helixTheme = "gruvbox";
        };
        "smohr" = mkHome {
          displayManager = "osx";
          username = "smohr";
          homeDirectory = "/Users/smohr";
          system = "aarch64-darwin";
          helixTheme = "rose_pine_moon";
          terminalFontSize = 14;
        };
      };

      nixosConfigurations = {
        "campfire" = mkNixos {
          hostname = "campfire";
          exposeSsh = true;
        };
        "smorestux" = mkNixos {
          hostname = "smorestux";
          displayManager = "niri";
        };
        "smoresbook" = mkNixos {
          hostname = "smoresbook";
          displayManager = "niri";
        };
      };
    };
}
