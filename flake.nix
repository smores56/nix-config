{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/241313f4e8e508cb9b13278c2b0fa25b9ca27163";
    # Newer bubblewrap and bitwarden-desktop than the main pin carries.
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    # Darwin builds from this: the main pin lacks the libffi trampoline fix, so nix Python aborts on
    # macOS 27. Fold back into `nixpkgs` once its pin has the fix.
    nixpkgs-darwin.url = "github:NixOS/nixpkgs/c9fe7d12cd78d1adcd12dd15e24432dde5b155a0";
    home-manager = {
      url = "github:nix-community/home-manager/041a999e8c1c5b731913855909e68d30ca69b8e0";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    niri = {
      url = "github:sodiboo/niri-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    noctalia = {
      url = "github:noctalia-dev/noctalia";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Its own greetd client keeps pam_p11's PIN prompt and the password prompt distinct; tuigreet can't.
    noctalia-greeter = {
      url = "github:noctalia-dev/noctalia-greeter/af0bf4b1e1c40738db917b04c9c0563b4f718953";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Pinned rev: a branch would change the signing and boot-entry layout on every lock update.
    lanzaboote = {
      url = "github:nix-community/lanzaboote/c1c5edd31802d181c8aa2c71588995d93425d650";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    concord = {
      url = "github:chojs23/concord";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    stylix = {
      # HM 26.11 pin tracks master and stylix has no release-26.11 branch yet.
      url = "github:nix-community/stylix/66714e5ce44269ecc58c20d9196da8dbe1b27a31";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-parts.url = "github:hercules-ci/flake-parts";
    import-tree.url = "github:vic/import-tree";
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    disko = {
      url = "github:nix-community/disko/latest";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # The Linux agent VM (modules/nixos/agent-vm.nix).
    microvm = {
      url = "github:microvm-nix/microvm.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # The kanbei control-plane agent, installed in the guest (modules/nixos/kanbei-agent.nix).
    # The repo is private, so the input is fetched over SSH and the lock pins the revision;
    # it pins the same nixpkgs rev as this flake, hence `follows`.
    kanbei = {
      url = "git+ssh://git@github.com/smores56/kanbei";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # nanobot's Python environment: uv2nix builds the locked wheel set.
    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
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
