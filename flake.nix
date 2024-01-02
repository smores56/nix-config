{
  description = "My Home Manager Flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    helix.url = "github:helix-editor/helix";
    stylix.url = "github:danth/stylix";
  };

  outputs = { nixpkgs, home-manager, helix, stylix, ... }:
    let
      localOverlay = prev: final: {
        helix = helix.packages.${prev.system}.helix;
        stylix = stylix.packages.${prev.system}.stylix;
      };

      pkgsForSystem = system: import nixpkgs {
        overlays = [
          localOverlay
        ];
        inherit system;
        config = { allowUnfree = true; };
      };

      mkHomeConfiguration = args: home-manager.lib.homeManagerConfiguration (rec {
        pkgs = pkgsForSystem (args.extraSpecialArgs.system or "x86_64-linux");
        inherit (args) extraSpecialArgs;

        modules = [
          ./modules/tools
          {

            home = {
              stateVersion = "23.11";
              packages = [ pkgs.home-manager ];
              username = args.extraSpecialArgs.username or "smores";
              homeDirectory = args.extraSpecialArgs.homeDirectory or "/home/smores";
            };
          }
        ]
        ++ (if pkgs.stdenv.isLinux then [
          {
            xdg.enable = true;
            xdg.mime.enable = true;
            targets.genericLinux.enable = true;
            xdg.systemDirs.data =  [
              "${args.extraSpecialArgs.homeDirectory or "/home/smores"}/.nix-profile/share/applications"
            ];
          }
        ] else [ ])
        ++ (if (args.extraSpecialArgs.gui or false) then [
          ./modules/hyprland
          ./modules/gui
        ] else [ ])
        ++ (if (args.extraSpecialArgs.wezterm or false) then [
          ./modules/gui/terminal/wezterm.nix
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
        "smohr" = mkHomeConfiguration {
          extraSpecialArgs = {
            username = "smohr";
            homeDirectory = "/Users/smohr";
            system = "aarch64-darwin";
            wezterm = true;
            lightTheme = false;
          };
        };
      };
    };
}
