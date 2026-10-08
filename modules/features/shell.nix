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

  # Renames the tab holding this shell's pane, not the focused one, which
  # differs once you switch tabs while a command runs. Shells compute the
  # name themselves and run this in the background, since each zellij client
  # call costs ~16ms.
  zellijTabRename = pkgs.writeShellApplication {
    name = "zellij-tab-rename";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
    ];
    text = ''
      [ -n "''${ZELLIJ_PANE_ID:-}" ] || exit 0
      tab=$(timeout 2 zellij action list-panes -j 2>/dev/null |
        jq -r --argjson p "$ZELLIJ_PANE_ID" '.[] | select((.is_plugin | not) and .id == $p) | .tab_id' 2>/dev/null)
      [ -n "$tab" ] || exit 0
      timeout 2 zellij action rename-tab-by-id -- "$tab" "$1" >/dev/null 2>&1 || true
    '';
  };
  tabRename = lib.getExe zellijTabRename;

  # Init scripts that only depend on the tool's version and flags, generated
  # at build time so shells source a file instead of spawning the tool.
  initScript = name: cmd: pkgs.runCommand name { } "${cmd} > $out";
  fzf = lib.getExe config.programs.fzf.package;
  zoxide = "${lib.getExe config.programs.zoxide.package} init";
  zoxideFlags = lib.escapeShellArgs config.programs.zoxide.options;
  fzfZsh = initScript "fzf-init.zsh" "${fzf} --zsh";
  fzfFish = initScript "fzf-init.fish" "${fzf} --fish";
  zoxideZsh = initScript "zoxide-init.zsh" "${zoxide} zsh ${zoxideFlags}";
  zoxideFish = initScript "zoxide-init.fish" "${zoxide} fish ${zoxideFlags}";

  # Fish-style abbreviations: expand the command word on space or enter.
  zshAbbrs = lib.concatStringsSep " " (
    lib.mapAttrsToList (k: v: "${lib.escapeShellArg k} ${lib.escapeShellArg v}") cfg.shellAbbrs
  );

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
      zellijTabRename
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
    # Sourced from build-time init scripts below instead.
    fzf = {
      enableZshIntegration = false;
      enableFishIntegration = false;
    };

    zoxide = {
      enable = true;
      enableZshIntegration = false;
      enableFishIntegration = false;
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

      interactiveShellInit = lib.mkMerge [
        # Where HM put its fzf integration.
        (lib.mkOrder 200 "source ${fzfFish}")
        ''
          source ${zoxideFish}
          pfetch
          for p in $NIX_PROFILES
              set -a fish_function_path $p/share/fish/vendor_functions.d
              set -a fish_complete_path $p/share/fish/vendor_completions.d
          end
        ''
      ];

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

        # Auto-name Zellij tabs after the repo (or dir) on every prompt
        # (covers `cd`/zoxide `c`/manual navigations), plus the command
        # before each one runs. Renames go out in the background and only
        # when the name changes.
        _zellij_tab_title.body = ''
          set -l dir $PWD
          while test "$dir" != /; and not test -e $dir/.git
              set dir (path dirname -- $dir)
          end
          set -l name (path basename -- $PWD)
          if test -e $dir/.git
              set name (path basename -- $dir)
          else if test "$PWD" = "$HOME"
              set name '~'
          end
          if set -q argv[1]
              set -l cmd (string split -f1 -- ' ' $argv[1])
              test (string length -- $cmd) -le 20; or set cmd (string sub -l 17 -- $cmd)...
              set name "$name - $cmd"
          end
          echo $name
        '';
        _zellij_tab_rename.body = ''
          test "$argv[1]" = "$_ztn_last"; and return
          set -g _ztn_last $argv[1]
          ${tabRename} $argv[1] &
          set -g _ztn_pid $last_pid
          disown $_ztn_pid 2>/dev/null
        '';
        _zellij_tab_name = {
          body = ''
            set -q ZELLIJ; or return
            # A fast command's preexec rename may still be in flight and
            # land after this one; kill it so the newest name wins. Only
            # for short commands, so the pid can't have been reused.
            if set -q _ztn_pid; and test "$CMD_DURATION" -lt 2000
                kill $_ztn_pid 2>/dev/null
            end
            _zellij_tab_rename (_zellij_tab_title)
            # Only preexec renames are tracked for killing.
            set -e _ztn_pid
          '';
          onEvent = [ "fish_prompt" ];
        };
        _zellij_tab_name_preexec = {
          body = ''
            set -q ZELLIJ; or return
            set -e _ztn_pid
            _zellij_tab_rename (_zellij_tab_title $argv[1])
          '';
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
      dotDir = "${config.xdg.configHome}/zsh";
      autosuggestion.enable = true;
      syntaxHighlighting.enable = true;
      historySubstringSearch.enable = true;

      # compaudit (most of compinit's ~27ms) only matters when fpath changes,
      # and fpath comes from the HM generation and the Nix profile, so key the
      # dump on both: a switch rebuilds it once, other starts skip the audit.
      completionInit = ''
        autoload -U compinit
        () {
          local hm=$HOME/.local/state/nix/profiles/home-manager prof=$HOME/.nix-profile
          local dump=$ZDOTDIR/.zcompdump-''${''${''${hm:A}:t}[1,12]}-''${''${''${prof:A}:t}[1,12]}
          if [[ -e $dump ]]; then
            compinit -C -d $dump
          else
            compinit -d $dump
            # Spare this key's files: a concurrent shell may be mid-write.
            setopt local_options extended_glob
            rm -f $ZDOTDIR/.zcompdump*~$dump*(N)
          fi
        }
      '';
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

        # Where HM put the zoxide and fzf integrations.
        (lib.mkOrder 851 "source ${zoxideZsh}")
        (lib.mkOrder 910 ''
          if [[ $options[zle] = on ]]; then
            source ${fzfZsh}
          fi
        '')

        (lib.mkOrder 1000 ''
          fpath+=(${pkgs.pure-prompt}/share/zsh/site-functions)

          typeset -gA _abbrs=(${zshAbbrs})
          # Only the whole command word expands, as in fish; Ctrl-Space types
          # a plain space. Replacing accept-line covers every key bound to it.
          _abbr_expand() {
            [[ $LBUFFER =~ '^ *([^ ]+)$' && $RBUFFER != [^\ ]* ]] && (( $+_abbrs[$match[1]] )) &&
              LBUFFER=''${LBUFFER%$match[1]}$_abbrs[$match[1]]
          }
          _abbr_space() { _abbr_expand; zle self-insert }
          _abbr_accept() { _abbr_expand; zle .accept-line }
          zle -N _abbr_space
          zle -N accept-line _abbr_accept
          bindkey ' ' _abbr_space
          bindkey '^ ' magic-space
          bindkey -M isearch ' ' self-insert
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

          # Auto-name Zellij tabs after the repo (or dir) on every prompt,
          # plus the command before each one runs. Renames go out in the
          # background and only when the name changes.
          _zellij_tab_title() {
            local dir=$PWD name=''${PWD:t}
            while [[ $dir != / && ! -e $dir/.git ]]; do dir=''${dir:h}; done
            if [[ -e $dir/.git ]]; then
              name=''${dir:t}
            elif [[ $PWD == $HOME ]]; then
              name='~'
            fi
            [[ -n $name ]] || name=/
            if (( $# )); then
              local cmd=''${1%% *}
              (( $#cmd <= 20 )) || cmd="''${cmd[1,17]}..."
              name="$name - $cmd"
            fi
            REPLY=$name
          }
          _zellij_tab_rename() {
            [[ $1 == "''${_ztn_last-}" ]] && return
            _ztn_last=$1
            ${tabRename} "$1" &!
            _ztn_job=$!
          }
          _zellij_tab_name() {
            [[ -n ''${ZELLIJ-} ]] || return 0
            # A fast command's preexec rename may still be in flight and
            # land after this one; kill it so the newest name wins. Only
            # within 2s, so the pid can't have been reused.
            [[ -n ''${_ztn_pid-} ]] && (( EPOCHREALTIME - _ztn_at < 2 )) &&
              kill $_ztn_pid 2>/dev/null
            unset _ztn_pid
            _zellij_tab_title
            _zellij_tab_rename $REPLY
          }
          _zellij_tab_name_preexec() {
            [[ -n ''${ZELLIJ-} ]] || return 0
            unset _ztn_job
            _zellij_tab_title "$1"
            _zellij_tab_rename $REPLY
            [[ -n ''${_ztn_job-} ]] && _ztn_pid=$_ztn_job _ztn_at=$EPOCHREALTIME
          }
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
