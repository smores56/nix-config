{ config, pkgs, ... }:
let
  homeDir = config.home.homeDirectory;
in
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
      "${homeDir}/.local/bin"
      "${homeDir}/.deno/bin"
      "${homeDir}/.cargo/bin"
      "${homeDir}/.bun/bin"
      "${homeDir}/.cache/.bun/bin"
      "${homeDir}/.wasmtime/bin"
      "${homeDir}/.wasmer/bin"
      "${homeDir}/.brv-cli/bin"
    ];
  };

  manual.manpages.enable = false;

  programs = {
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
        t = "zellij";
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

        o = "nono run -s -- omp";
        m = "nono run -s -- maki";
        pi = "nono run -s -- pi";
        h = "herdr session attach default";
      };

      interactiveShellInit = ''
        for p in $NIX_PROFILES
            set -a fish_function_path $p/share/fish/vendor_functions.d
            set -a fish_complete_path $p/share/fish/vendor_completions.d
        end
        # Skip pfetch in OpenChamber - ANSI codes corrupt fenv.main parsing
        if not set -q TERM_PROGRAM; or ! string match -q "*OpenChamber*" $TERM_PROGRAM
            pfetch
        end
      '';

      # Auto-name Zellij tabs on every prompt (covers `cd`/zoxide `c`/manual
      # navigations). Renames only the default "Tab #N" title and our own
      # previously-set names — manually named tabs (e.g. `spawn_session`'s
      # explicit `-n`) are left alone. Two hooks: fish_prompt (cwd/git root)
      # and fish_preexec (running command). No-op outside Zellij.
      functions._zellij_tab_name = {
        body = ''
          set current (zellij action list-tabs --json --state 2>/dev/null \
            | jq -r '.[] | select(.active) | .name // ""' 2>/dev/null)
          if not test -n "$current"
              return
          end
          # Take over default ("Tab #N") tabs and our own previously-set
          # names; leave manually-renamed tabs alone (so spawn_session's
          # explicit -n persists across navigations).
          if not string match -qr '^Tab #[0-9]+$' -- "$current"
              and not test "$current" = "$_zellij_tab_name_last"
              return
          end
          set name (basename $PWD)
          test "$PWD" = "$HOME"; and set name "~"
          set root (${pkgs.coreutils}/bin/timeout 1 git rev-parse --show-toplevel 2>/dev/null)
          if test $status -eq 0; and test -n "$root"
              set name (basename "$root")
          end
          zellij action rename-tab -- "$name" 2>/dev/null
          set -g _zellij_tab_name_last "$name"
        '';
        onEvent = [ "fish_prompt" ];
      };

      functions._zellij_tab_name_preexec = {
        body = ''
          set current (zellij action list-tabs --json --state 2>/dev/null \
            | jq -r '.[] | select(.active) | .name // ""' 2>/dev/null)
          if not test -n "$current"
              return
          end
          if not string match -qr '^Tab #[0-9]+$' -- "$current"
              and not test "$current" = "$_zellij_tab_name_last"
              return
          end
          set cmd (string split ' ' -- $argv)[1]
          if test (string length -- "$cmd") -gt 20
              set cmd (string sub --length 17 -- "$cmd")"..."
          end
          zellij action rename-tab -- "$cmd" 2>/dev/null
          set -g _zellij_tab_name_last "$cmd"
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
