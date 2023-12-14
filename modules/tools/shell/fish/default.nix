{ pkgs, ... }: {
  home.packages = if pkgs.stdenv.isLinux then [ pkgs.nitch ] else [ pkgs.pfetch ];

  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  programs.zoxide = {
    enable = true;
    options = [ "--cmd" "c" ];
  };

  imports = [ ./functions.nix ];

  programs.fish = {
    enable = true;

    shellAbbrs = {
      # workflow apps
      e = "hx";
      ef = "hx (gum file .)";
      l = "eza --icons -lh";
      t = "zellij-picker";
      a = "mkdir -p";
      f = "yazi";
      b = "bat";
      g = "lazygit";
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
      sl = "ssh smoresnet -t fish";
      sm = "ssh smortress -t fish";
      sc = "ssh campfire -t fish";
      st = "ssh (tailscale-hosts | fzf) -t fish";
      pf = "port-forward smores@home.sammohr.dev";
    };

    interactiveShellInit = ''
      ${if pkgs.stdenv.isLinux then "nitch" else "pfetch"}
      set fish_greeting # custom prompt
      set -xg PATH /opt/homebrew/bin $PATH

      # include local extras if present
      for configFile in ~/.config/fish/extras/*.fish
          source $configFile
      end
    '';

    plugins = [
      { name = "done"; src = pkgs.fishPlugins.done.src; }
      { name = "pisces"; src = pkgs.fishPlugins.pisces.src; }
      {
        name = "lucid";
        src = pkgs.fetchFromGitHub {
          owner = "mattgreen";
          repo = "lucid.fish";
          rev = "c9aa46c1b59d40be49c37d92632baa1ea7093e9d";
          sha256 = "sha256-oydBnPMpR6iYcPv7P+DRCJBLOC/Uj77dGZXWz6y699I=";
        };
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
