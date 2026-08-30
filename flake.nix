{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/241313f4e8e508cb9b13278c2b0fa25b9ca27163";
    home-manager = {
      url = "github:nix-community/home-manager/041a999e8c1c5b731913855909e68d30ca69b8e0";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Fork adds extraConfig (upstream calls it `config`). TODO: switch back to
    # github:sodiboo/niri-flake when keybinds.nix migrates extraConfig → config.
    niri.url = "github:cmm/niri-flake/add-extraConfig";
    noctalia = {
      url = "github:noctalia-dev/noctalia-shell/2c1808f9f8937fc0b82c54af513f7620fec56d71";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    concord = {
      url = "github:chojs23/concord";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    stylix = {
      # Pinned to master HEAD tracking release 26.11 to match the HM 26.11
      # pin below; stylix has no release-26.11 branch yet (HM is on master).
      url = "github:nix-community/stylix/66714e5ce44269ecc58c20d9196da8dbe1b27a31";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-parts.url = "github:hercules-ci/flake-parts";
    import-tree.url = "github:vic/import-tree";
  };

  outputs =
    inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];
      inherit ((inputs.import-tree ./modules/flake)) imports;
    };
}
