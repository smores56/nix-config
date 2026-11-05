{
  config,
  lib,
  pkgs,
  ...
}:
let
  shell = config.user.shell;
  isFish = shell == "fish";
  isZsh = shell == "zsh";
  isServer = builtins.elem "server" config.machine.profiles;

  # Keeps the command in scrollback before the YubiKey touch. On the session PATH, not
  # home.packages, so Maki's sandbox PATH never sees it.
  sudoWrapper = pkgs.writeShellScriptBin "sudo" ''
    printf 'sudo: %s\n' "$*" >&2
    exec /run/wrappers/bin/sudo "$@"
  '';

  # A reconnect kills the forwarded agent path; panes use a stable symlink the next login repoints.
  sshAuthSockHookFish = builtins.readFile ./ssh-auth-sock.fish;
  sshAuthSockHookZsh = builtins.readFile ./ssh-auth-sock.zsh;

  # Renames the tab holding this shell's pane, not the focused one; backgrounded since each
  # zellij client call costs ~16ms.
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

  # Generated at build time so shells source a file instead of spawning the tool.
  initScript = name: cmd: pkgs.runCommand name { } "${cmd} > $out";
  zoxide = "${lib.getExe config.programs.zoxide.package} init";
  zoxideFlags = lib.escapeShellArgs config.programs.zoxide.options;
  zoxideZsh = initScript "zoxide-init.zsh" "${zoxide} zsh ${zoxideFlags}";
  zoxideFish = initScript "zoxide-init.fish" "${zoxide} fish ${zoxideFlags}";

  zshAbbrs = lib.concatStringsSep " " (
    lib.mapAttrsToList (k: v: "${lib.escapeShellArg k} ${lib.escapeShellArg v}") config.user.shellAbbrs
  );

  zshPathInit = ''
    unset __ETC_PROFILE_NIX_SOURCED __HM_SESS_VARS_SOURCED
    if [[ -e /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]]; then
      . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
    fi
    . "${config.home.sessionVariablesPackage}/etc/profile.d/hm-session-vars.sh"
    # Non-login shells (zellij panes) skip path_helper and the employer's ~/.zshrc needs brew; append it so Nix still wins.
    typeset -U path
    [[ -d /opt/homebrew/bin ]] && path+=(/opt/homebrew/bin /opt/homebrew/sbin)
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

    # No /opt/homebrew/bin or /usr/local/bin: path_helper already adds them
    # after Nix, and listing them here would shadow Nix's gh wrapper.
    sessionPath = lib.optionals isServer [ "${sudoWrapper}/bin" ] ++ [
      "${config.home.homeDirectory}/.local/bin"
      "${config.home.homeDirectory}/.deno/bin"
      "${config.home.homeDirectory}/.cargo/bin"
      "${config.home.homeDirectory}/.bun/bin"
      "${config.home.homeDirectory}/.cache/.bun/bin"
      "${config.home.homeDirectory}/.wasmer/bin"
    ];
  };

  manual.manpages.enable = false;

  # One string per abbreviation for both shells; pickers go through each renderer's `pick`.
  user.shellAbbrs = lib.mkMerge [
    {
      e = "hx";
      ef = "pick files hx";
      et = "pick text hx";
      l = "eza --icons -lh";
      t = "zellij a -c main";
      a = "mkdir -p";
      f = "yazi";
      b = "bat";
      g = "lazygit";
      gp = "gh pr create";
      copy = "osc copy";
      paste = "osc paste";

      cn = "c ~/repos/github.com/smores56/nix-config";
      hm = "home-manager";
      hs = "home-manager switch --no-write-lock-file";

      ng = "nix-collect-garbage --delete-old";

      sm = "ssh smores@smortress -t fish";
    }
    (lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
      ns = "sudo nixos-rebuild --flake ~/.config/home-manager switch --upgrade";
    })
  ];

  programs = {
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
      shellInit = lib.mkMerge [
        (lib.mkIf (!config.machine.nixos) ''
          if test -e /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.fish
              source /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.fish
          end
        '')
        (lib.mkIf config.machine.nixos ''
          if test -r /run/secrets/neuralwatt-api-key
              set -gx NEURALWATT_API_KEY (cat /run/secrets/neuralwatt-api-key)
          end
          if test -r /run/secrets/tinyfish-api-key
              set -gx TINYFISH_API_KEY (cat /run/secrets/tinyfish-api-key)
          end
        '')
        (lib.mkIf isServer (lib.mkAfter sshAuthSockHookFish))
      ];

      inherit (config.user) shellAbbrs;

      interactiveShellInit = lib.mkMerge [
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
        # pick <channel> <command…>: runs the picker, then the command in this shell (so `c` can cd)
        # with the selection appended or substituted for {name}. Cancelling runs nothing.
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
            # A fast command's preexec rename may land after this one; kill it so the newest wins
            # (short commands only, so the pid cannot be reused).
            if set -q _ztn_pid; and test "$CMD_DURATION" -lt 2000
                kill $_ztn_pid 2>/dev/null
            end
            _zellij_tab_rename (_zellij_tab_title)
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

    zsh = lib.mkIf isZsh {
      enable = true;
      # HM owns $ZDOTDIR; ~/.zshrc stays a plain file for tools that append their own blocks.
      dotDir = "${config.xdg.configHome}/zsh";
      autosuggestion.enable = true;
      syntaxHighlighting.enable = true;
      historySubstringSearch.enable = true;

      # compaudit only matters when fpath changes; key the dump on the HM generation and Nix profile so a switch rebuilds it once.
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

      # The installer's /etc/zshenv loads Nix only for ssh logins, then /etc/zprofile's path_helper puts
      # system dirs ahead of Nix and HM. Both files rebuild fish's order: HM sessionPath, Nix profile, system.
      envExtra = lib.mkMerge [
        (lib.mkIf (!config.machine.nixos) zshPathInit)
        (lib.mkIf isServer (lib.mkAfter sshAuthSockHookZsh))
      ];
      profileExtra = lib.mkIf (!config.machine.nixos) zshPathInit;

      initContent = lib.mkMerge [
        (lib.mkOrder 550 ''
          zstyle ':completion:*' menu select
          zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}' 'r:|[._-]=* r:|=*'
        '')

        # After compinit (its completion blocks need it), before the interactive layer so its PATH entries win.
        (lib.mkOrder 600 ''
          if [[ -f ~/.zshrc ]]; then
            source "$HOME/.zshrc"
          fi
        '')

        (lib.mkOrder 851 "source ${zoxideZsh}")

        (lib.mkOrder 1000 ''
          fpath+=(${pkgs.pure-prompt}/share/zsh/site-functions)

          typeset -gA _abbrs=(${zshAbbrs})
          # Only the whole command word expands, as in fish; Ctrl-Space types a plain space.
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
            # A fast command's preexec rename may land after this one; kill it so the newest wins
            # (within 2s, so the pid cannot be reused).
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

          # Like fish's `done`: notify after 10s+ commands while the terminal is unfocused (not over ssh,
          # where it would land on the other machine).
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
