{
  description = "My Home Manager Flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    stylix.url = "github:danth/stylix";
  };

  outputs = { nixpkgs, home-manager, stylix, ... }:
    let
      localOverlay = prev: final: {
        stylix = stylix.packages.${prev.system}.stylix;
      };

      pkgsForSystem = system: import nixpkgs {
        inherit system;
        overlays = [ localOverlay ];
        config = { allowUnfree = true; };
      };

      mkHomeConfiguration = args: home-manager.lib.homeManagerConfiguration (rec {
        extraSpecialArgs = (rec {
          system = args.system or "x86_64-linux";
          isLinux = system == "x86_64-linux";
          polarity = args.polarity or "either";
        } // args);
        pkgs = pkgsForSystem extraSpecialArgs.system;
        modules = [ stylix.homeManagerModules.stylix ./modules/home.nix ];
      });
    in
    {
      homeConfigurations = {
        "smores@smoresbook" = mkHomeConfiguration {
          machineType = "laptop";
          wallpaper = ./wallpapers/enchanted-evening-retreat.png;
        };
        "smores@campfire" = mkHomeConfiguration {
          machineType = "server";
        };
        "smores@smortress" = mkHomeConfiguration {
          machineType = "desktop";
          polarity = "dark";
          wallpaper = ./wallpapers/angled-waves.png;
          colorscheme = "gruvbox-material-dark-medium";
        };
        "smores@smoresnet" = mkHomeConfiguration {
          machineType = "server";
        };
        "smohr" = mkHomeConfiguration {
          machineType = "laptop";
          username = "smohr";
          homeDirectory = "/Users/smohr";
          system = "aarch64-darwin";
          colorscheme = "kanagawa";
        };
      };
    };
}
