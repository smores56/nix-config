{
  description = "My Home Manager Flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    helix.url = "github:helix-editor/helix";
    comma.url = "github:nix-community/comma";
    nixgl.url = "github:guibou/nixGL";
  };

  outputs = { nixpkgs, home-manager, nixgl, helix, comma, ... }:
    let
      localOverlay = prev: final: {
        helix = helix.packages.${prev.system}.helix;
        comma = comma.packages.${prev.system}.comma;
        nixgl = nixgl.packages.${prev.system}.nixGLIntel;
      };

      pkgsForSystem = system: import nixpkgs {
        overlays = [
          localOverlay
        ];
        inherit system;
        config = { allowUnfree = true; };
      };

      mkHomeConfiguration = args: home-manager.lib.homeManagerConfiguration (rec {
        pkgs = pkgsForSystem (args.system or "x86_64-linux");

        modules = [
          ./modules/tools
          {
            xdg.enable = true;
            xdg.mime.enable = true;
            targets.genericLinux.enable = true;
            xdg.systemDirs.data = [
              "${args.homeDirectory or "/home/smores"}/.nix-profile/share/applications"
            ];

            home = {
              stateVersion = "23.11";
              packages = [ pkgs.home-manager ];
              username = args.username or "smores";
              homeDirectory = args.homeDirectory or "/home/smores";
            };
          }
        ] ++ (if args.extraSpecialArgs.gui then [
          ./modules/hyprland
          ./modules/gui
        ] else [ ]);
      } // args);
    in
    {
      defaultPackage.x86_64-linux = home-manager.defaultPackage.x86_64-linux;

      homeConfigurations = {
        "smores@smoresbook" = mkHomeConfiguration {
          extraSpecialArgs = {
            gui = true;
            wallpaper = ./wallpapers/windmills.jpg;
            lightTheme = false;
          };
        };
        "smores@campfire" = mkHomeConfiguration {
          extraSpecialArgs = {
            gui = true;
            lightTheme = false;
          };
        };
        "smores@smortress" = mkHomeConfiguration {
          extraSpecialArgs = {
            gui = true;
            wallpaper = ./wallpapers/rocket-launch.png;
            lightTheme = false;
          };
        };
        "smores@smoresnet" = mkHomeConfiguration {
          extraSpecialArgs = {
            gui = false;
            lightTheme = false;
          };
        };
      };
    };
}
