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

  prefix = "${cfg.branchPrefix}/";
in
{
  home.packages = [
    pkgs.ghq
    gwq
  ];

  xdg.configFile."gwq/config.toml".text = ''
    [worktree]
    basedir = "~/dev/worktrees"
  '';

  programs = {
    git.settings.ghq.root = "~/dev/repos";

    fish = {
      shellAbbrs = {
        r = "repo";
        w = "wt";
        nw = "gwq add -b ${prefix}";
        nb = "git checkout -b ${prefix}";
      };

      functions = {
        repo = {
          description = "Navigate to a ghq repo via fzf";
          body = ''
            set -l root (ghq root)
            ghq list | fzf --preview "eza --icons -lh $root/{} | head -30" | read -l selected
            and c $root/$selected
          '';
        };
        wt = {
          description = "Navigate to a gwq worktree via fzf";
          body = ''
            gwq list | fzf --preview "git -C {} log --oneline -10" | read -l selected
            and c $selected
          '';
        };
      };
    };
  };
}
