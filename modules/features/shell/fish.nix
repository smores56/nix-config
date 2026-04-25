{ pkgs, ... }:
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

  home.sessionVariables = {
    async_prompt_functions = "_pure_prompt_git";
    fish_greeting = "";
  };

  manual.manpages.enable = false;
  programs.man.generateCaches = false;
  programs.fish.generateCompletions = false;

  programs.fish = {
    enable = true;

    shellAbbrs = {
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

      cn = "c ~/.config/nix";
      hm = "home-manager";
      hs = "home-manager switch --flake ~/.config/nix#$USER@(hostname) --no-write-lock-file";

      ns = "sudo nixos-rebuild --flake ~/.config/nix switch --upgrade";
      nsr = "nix-store --repair --verify --check-contents";
      ng = "nix-collect-garbage";

      sl = "ssh smores@smoresnet -t fish";
      sm = "ssh smores@smortress -t fish";
      sc = "ssh smores@campfire -t fish";
      st = "ssh smores@(tailscale-hosts | fzf) -t fish";
      pf = "port-forward smores@home.sammohr.dev";

      olu = "ollama run $OPENAI_MODEL";
    };

    interactiveShellInit = ''
      fish_add_path /opt/homebrew/bin /usr/local/bin ~/.local/bin ~/.deno/bin
      for p in $NIX_PROFILES
          set -a fish_function_path $p/share/fish/vendor_functions.d
          set -a fish_complete_path $p/share/fish/vendor_completions.d
      end
      pfetch
      function __deferred_zellij_tabname --on-event fish_prompt
          functions --erase __deferred_zellij_tabname
          __auto_zellij_update_tabname
      end
    '';

    plugins =
      map
        (name: {
          inherit name;
          src = pkgs.fishPlugins.${name}.src;
        })
        [
          "done"
          "pure"
          "async-prompt"
        ];
  };
}
