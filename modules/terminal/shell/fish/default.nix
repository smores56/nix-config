{
  lib,
  pkgs,
  displayManager,
  ...
}:
{
  stylix.targets.fish.enable = lib.mkIf (displayManager != null) true;

  home.packages = [ pkgs.pfetch-rs ];

  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  programs.zoxide = {
    enable = true;
    options = [
      "--cmd"
      "c"
    ];
  };

  imports = [ ./functions.nix ];

  # configure fish-async-prompt
  home.sessionVariables = {
    async_prompt_functions = "_pure_prompt_git";
    OLLAMA_API_BASE = "http://smortress:11434";
  };

  programs.fish = {
    enable = true;

    shellAbbrs = {
      # workflow apps
      e = "hx";
      ef = "hx (fzf)";
      l = "eza --icons -lh";
      t = "zellij";
      a = "mkdir -p";
      f = "yazi";
      b = "bat";
      g = "lazygit";
      gs = "gh-dash";
      gn = "gh-notify";
      gc = "gh repo clone";

      # searching
      "/" = "fd --type f";
      "//" = "sk --ansi -i -c 'rg --color=always --line-number \"{}\"'";

      # theming
      dt = "set-theme dark";
      lt = "set-theme light";
      dts = "set-theme dark --select";
      lts = "set-theme light --select";

      # home manager
      cn = "c ~/.config/nix";
      hm = "home-manager";
      hs = "home-manager switch --flake ~/.config/nix";

      # nix
      ns = "sudo nixos-rebuild switch --upgrade";
      nsr = "nix-store --repair --verify --check-contents";
      ng = "nix-collect-garbage";

      # remote access
      sl = "ssh smores@smoresnet -t fish";
      sm = "ssh smores@smortress -t fish";
      sc = "ssh smores@campfire -t fish";
      st = "ssh smores@(tailscale-hosts | fzf) -t fish";
      pf = "port-forward smores@home.sammohr.dev";
    };

    interactiveShellInit = ''
      pfetch
      set fish_greeting # custom prompt
      set -xg PATH /opt/homebrew/bin /usr/local/bin ~/.local/bin $PATH
      set -xg AWS_REGION us-east-1

      # include local extras if present
      for configFile in ~/.config/fish/extras/*.fish
          source $configFile
      end
    '';

    plugins = [
      {
        name = "done";
        src = pkgs.fishPlugins.done.src;
      }
      {
        name = "pisces";
        src = pkgs.fishPlugins.pisces.src;
      }
      {
        name = "pure";
        src = pkgs.fishPlugins.pure.src;
      }
      {
        name = "async-prompt";
        src = pkgs.fishPlugins.async-prompt.src;
      }
      {
        name = "lf-icons";
        src = pkgs.fetchFromGitHub {
          owner = "joshmedeski";
          repo = "fish-lf-icons";
          rev = "d1c47b2088e0ffd95766b61d2455514274865b4f";
          sha256 = "sha256-6po/PYvq4t0K8Jq5/t5hXPLn80iyl3Ymx2Whme/20kc=";
        };
      }
      # Need this when using Fish as a default macOS shell in order to pick
      # up ~/.nix-profile/bin
      {
        name = "nix-env";
        src = pkgs.fetchFromGitHub {
          owner = "lilyball";
          repo = "nix-env.fish";
          rev = "00c6cc762427efe08ac0bd0d1b1d12048d3ca727";
          sha256 = "1hrl22dd0aaszdanhvddvqz3aq40jp9zi2zn0v1hjnf7fx4bgpma";
        };
      }
    ];
  };
}
