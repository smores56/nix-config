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
          displayManager = args.displayManager or null;
        } // args);
        pkgs = pkgsForSystem extraSpecialArgs.system;
        modules = [ stylix.homeManagerModules.stylix ./modules/home.nix ];
      });
    in
    {
      homeConfigurations = {
        "smores@smorestux" = mkHomeConfiguration {
          displayManager = "pop-os";
          colorscheme = "tender";
          polarity = "dark";
          wallpaper = ./wallpapers/spirited-away.jpg;
        };
        "smores@smoresbook" = mkHomeConfiguration {
          displayManager = "hyprland";
          polarity = "dark";
          wallpaper = ./wallpapers/enchanted-evening-retreat.png;
        };
        "smores@campfire" = mkHomeConfiguration {
          displayManager = null;
        };
        "smores@smortress" = mkHomeConfiguration {
          displayManager = "hyprland";
          polarity = "dark";
          wallpaper = ./wallpapers/angled-waves.png;
          colorscheme = "gruvbox-material-dark-medium";
        };
        "smores@smoresnet" = mkHomeConfiguration {
          displayManager = null;
          polarity = "dark";
          colorscheme = "gruvbox-material-dark-medium";
        };
        "smohr" = mkHomeConfiguration {
          displayManager = "osx";
          username = "smohr";
          homeDirectory = "/Users/smohr";
          system = "aarch64-darwin";
          colorscheme = "rose-pine-dawn";
          polarity = "light";
          terminalFontSize = 12;
        };
      };
    };
}
