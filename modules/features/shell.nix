{ config, pkgs, ... }:
{
  home = {
    packages = [
      pkgs.osc
      pkgs.pfetch-rs
    ];

    sessionVariables = {
      async_prompt_functions = "_pure_prompt_git";
      fish_greeting = "";
    };

    sessionPath = [
      "/opt/homebrew/bin"
      "/usr/local/bin"
      "${config.home.homeDirectory}/.local/bin"
      "${config.home.homeDirectory}/.deno/bin"
      "${config.home.homeDirectory}/.cargo/bin"
      "${config.home.homeDirectory}/.bun/bin"
      "${config.home.homeDirectory}/.cache/.bun/bin"
      "${config.home.homeDirectory}/.wasmer/bin"
    ];
  };

  manual.manpages.enable = false;

  programs = {
    mise = {
      enable = true;
      enableFishIntegration = true;
      enableBashIntegration = true;
    };

    zoxide = {
      enable = true;
      options = [
        "--cmd"
        "c"
      ];
    };

    man.generateCaches = false;

    fish = {
      enable = true;
      generateCompletions = false;

      shellAbbrs = {
        e = "hx";
        ef = "tv | read -l f; and hx $f";
        et = "tv text | read -l f; and hx $f";
        l = "eza --icons -lh";
        t = "zellij a -c main";
        a = "mkdir -p";
        f = "yazi";
        b = "bat";
        g = "lazygit";
        gs = "gh dash";
        gn = "gh notify";
        gp = "gh pr create";
        copy = "osc copy";
        paste = "osc paste";

        cn = "c ~/code/github.com/smores56/nix-config";
        hm = "home-manager";
        hs = "home-manager switch --no-write-lock-file";

        ns = "sudo nixos-rebuild --flake ~/.config/home-manager switch --upgrade";
        ng = "nix-collect-garbage --delete-old";

        sm = "ssh smores@smortress -t fish";

        ab = "agentbox";
        o = "agentbox omp";
        m = "agentbox maki";
      };

      interactiveShellInit = ''
        for p in $NIX_PROFILES
            set -a fish_function_path $p/share/fish/vendor_functions.d
            set -a fish_complete_path $p/share/fish/vendor_completions.d
        end
      '';

      # Auto-name Zellij tabs on every prompt (covers `cd`/zoxide `c`/manual
      # navigations) and before each command. No-op outside Zellij.
      functions._zellij_tab_folder = {
        body = ''
          set name (basename $PWD)
          test "$PWD" = "$HOME"; and set name "~"
          set root (${pkgs.coreutils}/bin/timeout 1 git rev-parse --show-toplevel 2>/dev/null)
          if test $status -eq 0; and test -n "$root"
              set name (basename "$root")
          end
          echo "$name"
        '';
      };

      functions._zellij_tab_name = {
        body = ''
          zellij action rename-tab -- (_zellij_tab_folder) 2>/dev/null
        '';
        onEvent = [ "fish_prompt" ];
      };

      functions._zellij_tab_name_preexec = {
        body = ''
          set cmd (string split ' ' -- $argv)[1]
          if test (string length -- "$cmd") -gt 20
              set cmd (string sub --length 17 -- "$cmd")"..."
          end
          set folder (_zellij_tab_folder)
          zellij action rename-tab -- "$folder - $cmd" 2>/dev/null
        '';
        onEvent = [ "fish_preexec" ];
      };

      plugins =
        map
          (name: {
            inherit name;
            inherit (pkgs.fishPlugins.${name}) src;
          })
          [
            "done"
            "pure"
            "async-prompt"
          ];
    };
  };
}
