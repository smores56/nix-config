{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/f83fc3c307e74bc5fd5adb7eb6b8b13ffd2a36e1";
    home-manager = {
      url = "github:nix-community/home-manager/57d5560ee92a424fb71fde800acd6ed2c725dfce";
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
    smolvm.url = "github:smol-machines/smolvm";
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
