{
  pkgs,
  ...
}:
{
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
    fish_greeting = "";
  };

  # Make man-cache builds much faster
  programs.man.generateCaches = false;
  programs.fish.generateCompletions = false;

  programs.fish = {
    enable = true;

    shellAbbrs = {
      # workflow apps
      e = "hx";
      ef = "tv | read -l f; and hx $f";
      et = "tv text | read -l f; and hx $f";
      l = "eza --icons -lh";
      t = "zellij";
      a = "mkdir -p";
      f = "yazi";
      b = "bat";
      g = "lazygit";
      gs = "gh dash";
      gn = "gh notify";
      gp = "gh pr create";
      gc = "gh repo clone";

      # home manager
      cn = "c ~/.config/nix";
      hm = "home-manager";
      hs = "home-manager switch --flake ~/.config/nix#$USER --no-write-lock-file";

      # nix
      ns = "sudo nixos-rebuild --flake ~/.config/nix switch --upgrade";
      nsr = "nix-store --repair --verify --check-contents";
      ng = "nix-collect-garbage";

      # remote access
      sl = "ssh smores@smoresnet -t fish";
      sm = "ssh smores@smortress -t fish";
      sc = "ssh smores@campfire -t fish";
      st = "ssh smores@(tailscale-hosts | fzf) -t fish";
      pf = "port-forward smores@home.sammohr.dev";

      # AI calling
      olu = "ollama run $OPENAI_MODEL";
    };

    interactiveShellInit = ''
      pfetch
      __auto_zellij_update_tabname
      fish_add_path /opt/homebrew/bin /usr/local/bin ~/.local/bin ~/.deno/bin
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
