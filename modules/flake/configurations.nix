{ inputs, ... }:
let
  inherit (inputs)
    home-manager
    niri
    noctalia
    paneru
    stylix
    ;
  inherit (inputs.nixpkgs) lib;

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
    paneru.homeModules.paneru
    stylix.homeModules.stylix
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
      extraSpecialArgs = {
        inherit inputs;
      };
      modules = homeModules ++ [
        {
          dotfiles = {
            inherit username;
          }
          // builtins.intersectAttrs {
            displayManager = "none";
            windowManager = "none";
            terminalFontSize = null;
            polarity = null;
            exposeSsh = null;
            nixos = null;
            email = null;
            darkTheme = null;
            lightTheme = null;
            llm = null;
            primaryMonitor = null;
            monitorSize = null;
            branchPrefix = null;
            ticketPrefix = null;
            workGithubOrgs = null;
            sevenqlLspPath = null;
            opencodeServe = null;
            opencodeHost = null;
          } args;
          home.username = username;
          home.homeDirectory =
            args.homeDirectory
              or (if lib.hasSuffix "-darwin" system then "/Users/${username}" else "/home/${username}");
        }
      ];
    };

  mkNixos =
    args:
    let
      dm = args.displayManager or "none";
      username = args.username or "smores";
    in
    inputs.nixpkgs.lib.nixosSystem {
      modules = [
        { nixpkgs.overlays = [ niri.overlays.niri ]; }
      ]
      ++ nixosModules
      ++ [
        ../hosts/${args.hostname}.nix
        {
          networking.hostName = args.hostname;
          dotfiles = {
            inherit username;
            displayManager = dm;
            exposeSsh = args.exposeSsh or false;
            fingerprint = args.fingerprint or false;
            nvidia = args.nvidia or false;
            llm = args.llm or false;
            persist = args.persist or false;
            opencodeServe = args.opencodeServe or false;
            opencodeHost = args.opencodeHost or { };
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
        polarity = "time-of-day";
        primaryMonitor = "eDP-1";
        monitorSize = {
          width = 1920;
          height = 1080;
        };
      };
      "smores@campfire" = mkHome {
        displayManager = "niri";
        nixos = true;
        polarity = "time-of-day";
        opencodeServe = true;
        opencodeHost = {
          enable = true;
          hostname = "campfire";
          bindAddress = "0.0.0.0";
          opencodePort = 4000;
          openchamberPort = 3000;
        };
      };
      "smores@smortress" = mkHome {
        displayManager = "niri";
        nixos = true;
        polarity = "time-of-day";
        primaryMonitor = "DP-2";
        monitorSize = {
          width = 5120;
          height = 2160;
        };
      };
      "smores@smoresnet" = mkHome { };
      "smohr@smoreswork" = mkHome {
        displayManager = "osx";
        windowManager = "aerospace";
        username = "smohr";
        system = "aarch64-darwin";
        terminalFontSize = 14;
        email = "sam.mohr@sevenai.com";
        branchPrefix = "sam.mohr";
        ticketPrefix = "7AI";
        workGithubOrgs = [ "OkamiAI" ];
        sevenqlLspPath = "/Users/smohr/dev/okami/typescript/tools/sevenql-lsp/main.ts";
        opencodeHost = {
          enable = true;
          hostname = "openchamber.local";
          bindAddress = "127.0.0.1";
          opencodePort = 16500;
          openchamberPort = 15500;
        };
      };
    };

    nixosConfigurations = {
      "campfire" = mkNixos {
        hostname = "campfire";
        exposeSsh = true;
        opencodeServe = true;
        opencodeHost = {
          enable = true;
          hostname = "campfire";
          bindAddress = "0.0.0.0";
          opencodePort = 4000;
          openchamberPort = 3000;
        };
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
      "smortress" = mkNixos {
        hostname = "smortress";
        displayManager = "niri";
        polarity = "time-of-day";
        exposeSsh = true;
        nvidia = true;
        llm = false;
        opencodeServe = true;
      };
    };
  };
}
