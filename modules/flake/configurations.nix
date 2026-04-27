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
    ../home.nix
  ]
  ++ importTree ../features
  ++ importTree ../desktop
  ++ [
    niri.homeModules.niri
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
            terminalFontSize = null;
            exposeSsh = null;
            nixos = null;
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
              fingerprint = args.fingerprint or false;
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
        nixos = true;
      };
      "smores@smoresbook" = mkHome {
        displayManager = "niri";
        nixos = true;
      };
      "smores@campfire" = mkHome {
        nixos = true;
      };
      "smores@smortress" = mkHome {
        displayManager = "pop-os";
      };
      "smores@smoresnet" = mkHome { };
      "smohr@smoreswork" = mkHome {
        displayManager = "osx";
        username = "smohr";
        homeDirectory = "/Users/smohr";
        system = "aarch64-darwin";
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
        fingerprint = true;
      };
    };
  };
}
