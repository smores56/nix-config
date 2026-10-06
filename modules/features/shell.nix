{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dotfiles;
  isFish = cfg.shell == "fish";
  isZsh = cfg.shell == "zsh";

  # Names the current Zellij tab after the repo (or dir), plus the running
  # command when given one; both shells call it from their prompt hooks.
  zellijTabName = pkgs.writeShellApplication {
    name = "zellij-tab-name";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.git
    ];
    text = ''
      [ -n "''${ZELLIJ:-}" ] || exit 0
      name=$(basename "$PWD")
      [ "$PWD" != "$HOME" ] || name="~"
      if root=$(timeout 1 git rev-parse --show-toplevel 2>/dev/null) && [ -n "$root" ]; then
        name=$(basename "$root")
      fi
      if [ $# -gt 0 ]; then
        cmd=''${1%% *}
        [ ''${#cmd} -le 20 ] || cmd="''${cmd:0:17}..."
        name="$name - $cmd"
      fi
      zellij action rename-tab -- "$name" 2>/dev/null || true
    '';
  };
  tabName = lib.getExe zellijTabName;

  zshPathInit = ''
    unset __ETC_PROFILE_NIX_SOURCED __HM_SESS_VARS_SOURCED
    if [[ -e /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]]; then
      . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
    fi
    . "${config.home.sessionVariablesPackage}/etc/profile.d/hm-session-vars.sh"
  '';
in
{
  home = {
    packages = [
      pkgs.osc
      pkgs.pfetch-rs
      zellijTabName
    ];

    sessionVariables = lib.mkIf isFish {
      async_prompt_functions = "_pure_prompt_git";
      fish_greeting = "";
      fish_terminal_skip_dsr = "1";
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

  # One string per abbreviation for both shells; pickers go through `pick`,
  # defined by each renderer below, since capturing output differs.
  dotfiles.shellAbbrs = {
    e = "hx";
    ef = "pick files hx";
    et = "pick text hx";
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

    m = "maki";
  };

  programs = {
    mise.enable = true;

    zoxide = {
      enable = true;
      options = [
        "--cmd"
        "c"
      ];
    };

    man.generateCaches = false;

    fish = lib.mkIf isFish {
      enable = true;
      generateCompletions = false;

      # Lix's installer only hooks /etc/{bash,zsh}rc, and nixpkgs' fish reads its
      # sysconfdir from the store, so non-NixOS hosts never get Nix on PATH.
      shellInit = lib.mkIf (!cfg.nixos) ''
        if test -e /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.fish
            source /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.fish
        end
      '';

      inherit (cfg) shellAbbrs;

      interactiveShellInit = ''
        pfetch
        for p in $NIX_PROFILES
            set -a fish_function_path $p/share/fish/vendor_functions.d
            set -a fish_complete_path $p/share/fish/vendor_completions.d
        end
      '';

      functions = {
        # pick <tv-channel> <command…>: runs the picker, then the command
        # (in this shell, so `c` can cd) with the selection appended or in
        # place of {name} (its basename). Cancelling runs nothing.
        pick.body = ''
          if test (count $argv) -lt 2
              echo 'usage: pick <tv-channel> <command…>' >&2
              return 2
          end
          set -l sel (tv $argv[1]); or return
          set sel $sel[1]
          test -n "$sel"; or return
          set -l cmd $argv[2..]
          if contains -- '{name}' $cmd
              set cmd (string replace -- '{name}' (path basename $sel) $cmd)
          else
              set -a cmd $sel
          end
          $cmd
        '';

        # Auto-name Zellij tabs on every prompt (covers `cd`/zoxide `c`/manual
        # navigations) and before each command.
        _zellij_tab_name = {
          body = "${tabName}";
          onEvent = [ "fish_prompt" ];
        };
        _zellij_tab_name_preexec = {
          body = "${tabName} $argv";
          onEvent = [ "fish_preexec" ];
        };
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

    # Fish emulation: pure prompt, real abbreviations, autosuggestions,
    # highlighting, prefix history search, `done`-style notifications.
    zsh = lib.mkIf isZsh {
      enable = true;
      # HM owns $ZDOTDIR; ~/.zshrc stays a plain file for tools that write
      # their own blocks into it (an employer setup tool, installers).
      dotDir = ".config/zsh";
      autosuggestion.enable = true;
      syntaxHighlighting.enable = true;
      historySubstringSearch.enable = true;
      zsh-abbr = {
        enable = true;
        abbreviations = cfg.shellAbbrs;
      };
      history = {
        # Keep the history a stock zsh already wrote.
        path = "${config.home.homeDirectory}/.zsh_history";
        size = 50000;
        save = 50000;
        ignoreAllDups = true;
      };

      # The installer's /etc/zshenv only loads Nix for ssh logins, and login
      # shells then run /etc/zprofile's path_helper, which moves the system
      # dirs ahead of Nix and HM. Both files rebuild the same order as fish:
      # HM's sessionPath, then the Nix profile, then the system.
      envExtra = lib.mkIf (!cfg.nixos) zshPathInit;
      profileExtra = lib.mkIf (!cfg.nixos) zshPathInit;

      initContent = lib.mkMerge [
        # Before compinit: fish-like menu completion, case-insensitive.
        (lib.mkOrder 550 ''
          zstyle ':completion:*' menu select
          zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}' 'r:|[._-]=* r:|=*'
        '')

        # The tool-owned rc, after compinit (its completion blocks need it)
        # and before the interactive layer, so its PATH entries win.
        (lib.mkOrder 600 ''
          if [[ -f ~/.zshrc ]]; then
            source "$HOME/.zshrc"
          fi
        '')

        (lib.mkOrder 1000 ''
          fpath+=(${pkgs.pure-prompt}/share/zsh/site-functions)
          autoload -U promptinit && promptinit && prompt pure

          pick() {
            local sel replaced=0 i
            (( $# >= 2 )) || { print -u2 'usage: pick <tv-channel> <command…>'; return 2 }
            sel=$(tv "$1") || return
            sel=''${sel%%$'\n'*}
            [[ -n $sel ]] || return
            shift
            local -a cmd=("$@")
            for i in {1..$#cmd}; do
              [[ $cmd[i] == '{name}' ]] && cmd[i]=''${sel:t} && replaced=1
            done
            (( replaced )) || cmd+=("$sel")
            "''${cmd[@]}"
          }

          autoload -Uz add-zsh-hook
          zmodload zsh/datetime

          _zellij_tab_name() { ${tabName} }
          _zellij_tab_name_preexec() { ${tabName} "$1" }
          add-zsh-hook precmd _zellij_tab_name
          add-zsh-hook preexec _zellij_tab_name_preexec

          # Like fish's `done`: notify when a command ran 10s or more while
          # the terminal wasn't the focused app (never over ssh, where the
          # notification would land on the other machine's screen).
          _done_preexec() { _done_start=$EPOCHREALTIME; _done_cmd=$1 }
          _done_precmd() {
            local rc=$? elapsed
            [[ -n ''${_done_start-} && -z ''${SSH_CONNECTION-} ]] || return 0
            elapsed=$(( EPOCHREALTIME - _done_start ))
            unset _done_start
            (( elapsed >= 10 )) || return 0
            local title="''${_done_cmd%% *} $( (( rc )) && print failed || print finished ) after ''${elapsed%.*}s"
            ${
              if pkgs.stdenv.hostPlatform.isDarwin then
                ''
                  [[ -n ''${__CFBundleIdentifier-} ]] && /usr/bin/lsappinfo info -only bundleID "$(/usr/bin/lsappinfo front)" 2>/dev/null | grep -q "\"$__CFBundleIdentifier\"" && return 0
                  # Text goes in as argv, never spliced into AppleScript source.
                  /usr/bin/osascript -e 'on run argv' -e 'display notification (item 1 of argv) with title (item 2 of argv)' -e 'end run' -- "$_done_cmd" "$title" >/dev/null 2>&1
                ''
              else
                ''
                  command -v notify-send >/dev/null && notify-send -- "$title" "$_done_cmd"
                ''
            }
            return 0
          }
          add-zsh-hook preexec _done_preexec
          add-zsh-hook precmd _done_precmd

          pfetch
        '')
      ];
    };
  };
}
