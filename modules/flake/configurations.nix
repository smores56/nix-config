{ inputs, ... }:
let
  inherit (inputs)
    home-manager
    niri
    noctalia
    ;

  importTree = path: (inputs.import-tree path).imports;

  pkgsForSystem =
    system:
    import inputs.nixpkgs {
      inherit system;
      config.allowUnfree = true;
      overlays = [
        niri.overlays.niri
        noctalia.overlays.default
      ];
    };

  homeModules = [
    ../options.nix
  ]
  ++ importTree ../home
  ++ importTree ../features
  ++ importTree ../desktop
  ++ [
    niri.homeModules.config
    noctalia.homeModules.default
  ];

  nixosModules = [ ../options.nix ] ++ importTree ../nixos;

  mkHome =
    args:
    let
      system = args.system or "x86_64-linux";
      username = args.username or "smores";
    in
    home-manager.lib.homeManagerConfiguration {
      pkgs = pkgsForSystem system;
      modules = homeModules ++ [
        {
          dotfiles = builtins.intersectAttrs {
            displayManager = null;
            polarity = null;
            helixTheme = null;
            terminalFontSize = null;
          } args;
          home.username = username;
          home.homeDirectory = args.homeDirectory or "/home/${username}";
        }
      ];
    };

  mkNixos =
    args:
    let
      dm = args.displayManager or null;
    in
    inputs.nixpkgs.lib.nixosSystem {
      modules =
        nixosModules
        ++ [
          ../hosts/${args.hostname}.nix
          {
            networking.hostName = args.hostname;
            dotfiles = {
              displayManager = dm;
              exposeSsh = args.exposeSsh or false;
            };
          }
        ]
        ++ (if dm == "niri" then [ niri.nixosModules.niri ] else [ ]);
    };
in
{
  flake = {
    homeConfigurations = {
      "smores@smorestux" = mkHome {
        displayManager = "niri";
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
