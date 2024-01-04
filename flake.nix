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

      mkHomeConfiguration = args: home-manager.lib.homeManagerConfiguration {
        pkgs = pkgsForSystem (args.system or "x86_64-linux");
        extraSpecialArgs = {
          polarity = args.polarity or "either";
        } // args;
        modules = [ stylix.homeManagerModules.stylix ./modules/home.nix ];
      };
    in
    {
      defaultPackage.x86_64-linux = home-manager.defaultPackage.x86_64-linux;

      homeConfigurations = {
        "smores" = mkHomeConfiguration {
          machineType = "laptop";
          polarity = "dark";
          wallpaper = ./wallpapers/enchanted-evening-retreat.png;
        };
        "smores@campfire" = mkHomeConfiguration {
          machineType = "desktop";
        };
        "smores@smortress" = mkHomeConfiguration {
          machineType = "desktop";
          wallpaper = ./wallpapers/rocket-launch.png;
        };
        "smores@smoresnet" = mkHomeConfiguration {
          machineType = "server";
        };
        "smohr" = mkHomeConfiguration {
          username = "smohr";
          homeDirectory = "/Users/smohr";
          system = "aarch64-darwin";
          machineType = "laptop";
        };
      };
    };
}
