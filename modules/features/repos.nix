{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.dotfiles;

  gwq = pkgs.buildGoModule {
    pname = "gwq";
    version = "0.1.1";

    src = pkgs.fetchFromGitHub {
      owner = "d-kuro";
      repo = "gwq";
      tag = "v0.1.1";
      hash = "sha256-MfCYFbODWnfPxx+6sLlcMT6tqghgILHB13+ccYqVjBA=";
    };

    vendorHash = "sha256-4K01Xf1EXl/NVX1loQ76l1bW8QglBAQdvlZSo7J4NPI=";

    subPackages = [ "cmd/gwq" ];

    ldflags = [
      "-s"
      "-w"
      "-X github.com/d-kuro/gwq/internal/cmd.version=v0.1.1"
    ];

    nativeBuildInputs = with pkgs; [
      installShellFiles
      makeWrapper
    ];

    postInstall = ''
      wrapProgram $out/bin/gwq \
        --prefix PATH : ${
          lib.makeBinPath [
            pkgs.gitMinimal
            pkgs.tmux
          ]
        }

      export HOME=$(mktemp -d)
      installShellCompletion --cmd gwq \
        --bash <($out/bin/gwq completion bash) \
        --fish <($out/bin/gwq completion fish) \
        --zsh <($out/bin/gwq completion zsh)
    '';

    meta = {
      description = "Git worktree manager with fuzzy finder";
      homepage = "https://github.com/d-kuro/gwq";
      license = lib.licenses.asl20;
      mainProgram = "gwq";
    };
  };

  gwq-cargo-link = pkgs.writeShellScriptBin "gwq-cargo-link" ''
    set -euo pipefail
    wt="''${1:?usage: gwq-cargo-link <worktree-path>}"
    [ -f "$wt/Cargo.toml" ] || exit 0
    main=$(git -C "$wt" worktree list --porcelain | head -1 | sed 's/^worktree //')
    [ "$main" = "$wt" ] && exit 0
    for profile in debug release; do
      src="$main/target/$profile"
      dst="$wt/target/$profile"
      mkdir -p "$src/deps" "$src/build" "$dst"
      for subdir in deps build; do
        [ -d "$dst/$subdir" ] && [ ! -L "$dst/$subdir" ] && rm -rf "$dst/$subdir"
        ln -sfn "$src/$subdir" "$dst/$subdir"
      done
    done
  '';

  gwq-node-link = pkgs.writeShellScriptBin "gwq-node-link" ''
    set -euo pipefail
    wt="''${1:?usage: gwq-node-link <worktree-path>}"
    [ -f "$wt/package.json" ] || exit 0
    main=$(git -C "$wt" worktree list --porcelain | head -1 | sed 's/^worktree //')
    [ "$main" = "$wt" ] && exit 0
    [ -d "$main/node_modules" ] || exit 0
    [ -d "$wt/node_modules" ] && [ ! -L "$wt/node_modules" ] && rm -rf "$wt/node_modules"
    ln -sfn "$main/node_modules" "$wt/node_modules"
  '';

  prefix = "${cfg.branchPrefix}/";
in
{
  home.packages = [
    pkgs.ghq
    gwq
    gwq-cargo-link
    gwq-node-link
  ];

  xdg.configFile."gwq/config.toml".text = ''
    [worktree]
    basedir = "~/dev/worktrees"

    [[repository_settings]]
    repository = "**"
    setup_commands = [
      "gwq-cargo-link '{{.Path}}'",
      "gwq-node-link '{{.Path}}'",
      "mise trust '{{.Path}}/mise.toml' 2>/dev/null || true",
    ]
  '';

  programs = {
    git.settings.ghq.root = "~/dev/repos";

    fish.shellAbbrs = {
      r = "ghq list | tv | read -l s; and c (ghq root)/$s";
      w = "gwq list | tv | read -l s; and c $s";
      nw = "gwq add -b ${prefix}";
      nb = "git checkout -b ${prefix}";
    };
  };
}
