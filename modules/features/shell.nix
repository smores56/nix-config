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

        o = "smolvm-agent omp";
        m = "smolvm-agent maki";
      };

      interactiveShellInit = ''
        for p in $NIX_PROFILES
            set -a fish_function_path $p/share/fish/vendor_functions.d
            set -a fish_complete_path $p/share/fish/vendor_completions.d
        end
      '';

      # Auto-name Zellij tabs on every prompt (covers `cd`/zoxide `c`/manual
      # navigations). Renames only the default "Tab #N" title and our own
      # previously-set names — manually named tabs (e.g. `spawn_session`'s
      # explicit `-n`, which embeds a sushi/π prefix) are left alone. Two hooks:
      # fish_prompt (cwd/git root) and fish_preexec (appends " - <cmd>"). The
      # folder part is shared via _zellij_tab_folder; running commands are
      # cleared at the next prompt. No-op outside Zellij.
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

      functions._zellij_tab_takeover = {
        body = ''
          set current (zellij action list-tabs --json --state 2>/dev/null \
            | jq -r '.[] | select(.active) | .name // ""' 2>/dev/null)
          if not test -n "$current"
              return 1
          end
          # Take over default ("Tab #N") tabs and our own previously-set
          # names; leave manually-renamed tabs alone (so spawn_session's
          # explicit -n persists across navigations).
          if not string match -qr '^Tab #[0-9]+$' -- "$current"
              and not test "$current" = "$_zellij_tab_name_last"
              return 1
          end
          return 0
        '';
      };

      functions._zellij_tab_name = {
        body = ''
          not _zellij_tab_takeover; and return
          set folder (_zellij_tab_folder)
          # No running command at the prompt → folder name only.
          set -g _zellij_tab_name_cmd ""
          zellij action rename-tab -- "$folder" 2>/dev/null
          set -g _zellij_tab_name_last "$folder"
        '';
        onEvent = [ "fish_prompt" ];
      };

      functions._zellij_tab_name_preexec = {
        body = ''
          not _zellij_tab_takeover; and return
          set cmd (string split ' ' -- $argv)[1]
          if test (string length -- "$cmd") -gt 20
              set cmd (string sub --length 17 -- "$cmd")"..."
          end
          set -g _zellij_tab_name_cmd "$cmd"
          set folder (_zellij_tab_folder)
          zellij action rename-tab -- "$folder - $cmd" 2>/dev/null
          set -g _zellij_tab_name_last "$folder - $cmd"
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
