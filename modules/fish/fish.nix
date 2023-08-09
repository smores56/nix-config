{ pkgs, ... }: {
  programs.starship.enable = true;
  programs.zoxide = {
    enable = true;
    options = [ "--cmd" "c" ];
  };

  imports = [ ./functions.nix ];

  programs.fish = {
    enable = true;

    shellAbbrs = {
      # workflow apps
      e = "$EDITOR";
      ef = "$EDITOR (gum file .)";
      l = "exa --icons -lh";
      t = "zellij-picker";
      a = "mkdir -p";
      f = "lfcd";
      b = "bat";
      g = "lazygit";
      gc = "gh repo clone";

      # searching
      "/" = "fd --type f";
      "//" = "sk --ansi -i -c 'rg --color=always --line-number \"{}\"'";

      # Arch Linux
      pi = "doas pacman -Sy";
      pr = "doas pacman -R";
      pq = "doas pacman -Q";

      # theming
      dt = "set-theme dark";
      lt = "set-theme light";
      dts = "set-theme dark --select";
      lts = "set-theme light --select";

      # dotfiles management
      cdf = "c ~/.local/share/chezmoi";
      cm = "chezmoi";
      ca = "chezmoi apply";

      # home manager
      hm = "home-manager";
      hs = "home-manager switch --flake ~/.config/nix/";

      # nix
      ns = "nixos-rebuild switch --upgrade";

      # remote access
      sl = "ssh smores@sammohr.dev -t";
      sm = "ssh smores@home.sammohr.dev -t";
      sc = "ssh smores@campfire.sammohr.dev -t";
      pf = "port-forward smores@home.sammohr.dev";
    };

    interactiveShellInit = ''
    # set custom prompt
    set fish_greeting

    # startup splashes
    if status --is-interactive
        # fetch sys info: https://github.com/willeccles/f
        f
    end
    '';

    plugins = [
      { name = "pisces"; src = pkgs.fishPlugins.pisces.src; }
      { name = "done"; src = pkgs.fishPlugins.done.src; }
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
