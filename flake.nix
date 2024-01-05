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
          wallpaper = ./wallpapers/spirited-away.jpg;
        };
        "smores@smoresnet" = mkHomeConfiguration {
          machineType = "server";
        };
        "smohr" = mkHomeConfiguration {
          machineType = "laptop";
          username = "smohr";
          homeDirectory = "/Users/smohr";
          system = "aarch64-darwin";
        };
      };
    };
}
