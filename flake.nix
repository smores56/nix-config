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
      url = "github:nix-community/stylix/84971726c7ef0bb3669a5443e151cc226e65c518";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-parts.url = "github:hercules-ci/flake-parts";
    import-tree.url = "github:vic/import-tree";
    # Pinned to last working rev: the 2026-07-22 release (c0c7e98) shipped a
    # truncated darwin-arm64 tarball. Revisit once upstream republishes.
    smolvm.url = "github:smol-machines/smolvm/2fce46c21875a221a4934e75875170dea74478e3";
    smolvm.inputs.nixpkgs.follows = "nixpkgs";
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
