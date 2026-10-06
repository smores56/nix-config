{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/241313f4e8e508cb9b13278c2b0fa25b9ca27163";
    # Only for rclone: the pinned nixpkgs ships 1.74.4, which predates the
    # Proton-API-Bridge v1.0.5 fix (rclone-created files were unreadable in
    # Proton's apps; rclone#9844). Bump with `nix flake update nixpkgs-unstable`.
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    # Darwin homes and checks build from this instead of `nixpkgs`: the main
    # pin predates the libffi trampoline fix (nixpkgs#541367, fixed in
    # 3f92b6968d74), so every nix Python aborts on macOS 27 at its first
    # ctypes callback. Separate from nixpkgs-unstable so rclone bumps don't
    # move the Macs; fold back into `nixpkgs` once its pin contains the fix.
    nixpkgs-darwin.url = "github:NixOS/nixpkgs/c9fe7d12cd78d1adcd12dd15e24432dde5b155a0";
    home-manager = {
      url = "github:nix-community/home-manager/041a999e8c1c5b731913855909e68d30ca69b8e0";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    niri.url = "github:sodiboo/niri-flake";
    noctalia.url = "github:noctalia-dev/noctalia";
    whisrs = {
      url = "github:y0sif/whisrs";
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
