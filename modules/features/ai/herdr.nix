{
  config,
  lib,
  pkgs,
  ...
}:
let
  dotfiles = config.dotfiles;
  cfg = dotfiles.herdrHost;
  enabled = cfg.enable && pkgs.stdenv.isLinux;

  phoneSession = lib.escapeShellArg cfg.session;
  bindAddress = lib.escapeShellArg cfg.bindAddress;
  port = toString cfg.port;
  tailscaleHttpsPort = toString cfg.tailscaleHttpsPort;
  targetUrl = "http://${cfg.bindAddress}:${port}";
  codeRoot = lib.escapeShellArg dotfiles.codeRoot;

  herdrVersion = "0.6.2";
  herdrAsset =
    if pkgs.stdenv.hostPlatform.system == "x86_64-linux" then
      "herdr-linux-x86_64"
    else
      throw "herdr-phone only packages Herdr for x86_64-linux right now";
  herdr = pkgs.stdenvNoCC.mkDerivation {
    pname = "herdr";
    version = herdrVersion;
    src = pkgs.fetchurl {
      url = "https://github.com/ogulcancelik/herdr/releases/download/v${herdrVersion}/${herdrAsset}";
      hash = "sha256-nuhReKCg2x/RUkMo6RvDe1fCVADuuk0Ka7LxvrY6AIk=";
    };
    dontUnpack = true;
    installPhase = ''
      install -Dm755 "$src" "$out/bin/herdr"
    '';
  };

  runtimePath = lib.makeBinPath [
    pkgs.coreutils
    pkgs.ghq
    pkgs.gnugrep
    pkgs.gum
    herdr
    pkgs.jq
    pkgs.systemd
    pkgs.tailscale
    pkgs.ttyd
  ];
  scriptPath = "${runtimePath}:${config.home.homeDirectory}/.local/bin:${config.home.homeDirectory}/.nix-profile/bin:/run/current-system/sw/bin:/run/wrappers/bin";
  pathPrelude = ''
    export PATH="${scriptPath}:$PATH"
  '';

  phoneSessionPrelude = ''
    phone_session=${phoneSession}
    export HERDR_SESSION="$phone_session"
    unset HERDR_SOCKET_PATH
  '';

  phoneHelpers = ''
    ${pathPrelude}
    ${phoneSessionPrelude}

    ensure_phone_server() {
      if herdr status server 2>/dev/null | grep -q '^status: running'; then
        return 0
      fi

      systemctl --user start herdr-phone-server.service

      for _ in 1 2 3 4 5; do
        if herdr status server 2>/dev/null | grep -q '^status: running'; then
          return 0
        fi
        sleep 0.2
      done

      echo "Herdr phone server did not start; run herdr-phone-logs for details." >&2
      return 1
    }

    workspace_label() {
      path="$1"
      if [ "$path" = "$HOME" ]; then
        printf '%s\n' "home"
        return
      fi

      parent="$(basename "$(dirname "$path")")"
      name="$(basename "$path")"
      if [ "$parent" = "." ] || [ "$parent" = "/" ]; then
        printf '%s\n' "$name"
      else
        printf '%s/%s\n' "$parent" "$name"
      fi
    }

    list_workspace_targets() {
      printf 'Home\t%s\n' "$HOME"
      ghq list -p | sort | while IFS= read -r repo; do
        [ -d "$repo" ] || continue
        label="$repo"
        case "$repo" in
          ${codeRoot}/*) label="''${repo#${dotfiles.codeRoot}/}" ;;
        esac
        printf '%s\t%s\n' "$label" "$repo"
      done
    }

    resolve_workspace_target() {
      query="$1"
      case "$query" in
        "" | home | Home | "~")
          printf '%s\n' "$HOME"
          return 0
          ;;
        /*)
          if [ -d "$query" ]; then
            realpath "$query"
            return 0
          fi
          ;;
      esac

      ghq list -p | while IFS= read -r repo; do
        [ -d "$repo" ] || continue
        rel="$repo"
        case "$repo" in
          ${codeRoot}/*) rel="''${repo#${dotfiles.codeRoot}/}" ;;
        esac
        parent="$(basename "$(dirname "$repo")")"
        name="$(basename "$repo")"
        short="$parent/$name"
        if [ "$query" = "$rel" ] || [ "$query" = "$short" ] || [ "$query" = "$name" ]; then
          printf '%s\n' "$repo"
          return 0
        fi
      done
    }

    choose_workspace_target() {
      if [ "$#" -gt 0 ]; then
        target="$(resolve_workspace_target "$1" | head -n 1)"
        if [ -z "$target" ]; then
          echo "No ghq repo or directory matched: $1" >&2
          return 1
        fi
        printf '%s\n' "$target"
        return 0
      fi

      choice="$(list_workspace_targets | gum filter --height 18 --placeholder "Herdr workspace")"
      [ -n "$choice" ] || return 1
      printf '%s\n' "$choice" | cut -f2-
    }

    focus_or_create_workspace() {
      target_path="$(realpath "$1")"
      label="$(workspace_label "$target_path")"

      workspace_id="$(
        herdr pane list 2>/dev/null \
          | jq -r --arg cwd "$target_path" '.result.panes[]? | select(.cwd == $cwd) | .workspace_id' \
          | head -n 1
      )"

      if [ -n "$workspace_id" ]; then
        herdr workspace focus "$workspace_id" >/dev/null
        return 0
      fi

      herdr workspace create --cwd "$target_path" --label "$label" --focus >/dev/null
    }
  '';

  herdrPhoneAttach = pkgs.writeShellScriptBin "herdr-phone" ''
    set -euo pipefail
    ${phoneHelpers}

    if ! command -v herdr >/dev/null 2>&1; then
      echo "herdr is not on PATH. Re-run home-manager switch for smortress." >&2
      exit 127
    fi

    ensure_phone_server
    target_path="$(choose_workspace_target "$@")"
    focus_or_create_workspace "$target_path"

    exec herdr session attach "$phone_session"
  '';

  herdrPhoneTtyd = pkgs.writeShellScriptBin "herdr-phone-ttyd" ''
    set -euo pipefail
    ${pathPrelude}

    exec ${pkgs.ttyd}/bin/ttyd \
      --interface ${bindAddress} \
      --port ${port} \
      --writable \
      --check-origin \
      --auth-header Tailscale-User-Login \
      -- ${herdrPhoneAttach}/bin/herdr-phone
  '';

  herdrPhoneServe = pkgs.writeShellScriptBin "herdr-phone-serve" ''
    set -euo pipefail
    ${phoneHelpers}

    if ! command -v herdr >/dev/null 2>&1; then
      echo "herdr is not on PATH. Re-run home-manager switch for smortress." >&2
      exit 127
    fi

    ensure_phone_server
    herdr server reload-config >/dev/null || true
    systemctl --user restart herdr-phone.service
    systemctl --user is-active --quiet herdr-phone.service

    set +e
    ${pkgs.coreutils}/bin/timeout 30s ${pkgs.tailscale}/bin/tailscale serve \
      --yes \
      --bg \
      --https=${tailscaleHttpsPort} \
      ${lib.escapeShellArg targetUrl}
    serve_status="$?"
    set -e
    if [ "$serve_status" -ne 0 ]; then
      if [ "$serve_status" -eq 124 ]; then
        echo "tailscale serve timed out. If Serve is disabled, open the Tailscale URL above, then rerun herdr-phone-serve." >&2
      fi
      exit "$serve_status"
    fi

    ${pkgs.tailscale}/bin/tailscale serve status
  '';

  herdrPhoneStatus = pkgs.writeShellScriptBin "herdr-phone-status" ''
    set +e
    ${phoneHelpers}

    printf 'herdr session: %s\n' "$phone_session"

    printf '\nherdr-phone-server.service: '
    systemctl --user is-active herdr-phone-server.service

    printf 'herdr-phone.service: '
    systemctl --user is-active herdr-phone.service

    printf '\nTailscale Serve:\n'
    ${pkgs.tailscale}/bin/tailscale serve status

    if command -v herdr >/dev/null 2>&1; then
      printf '\nHerdr server:\n'
      herdr status server

      printf '\nHerdr workspaces:\n'
      herdr workspace list
    fi
  '';

  herdrPhoneLogs = pkgs.writeShellScriptBin "herdr-phone-logs" ''
    ${pathPrelude}
    exec journalctl --user -u herdr-phone-server.service -u herdr-phone.service -f
  '';

  herdrOmpTab = pkgs.writeShellScriptBin "herdr-omp-tab" ''
    set -euo pipefail
    ${pathPrelude}

    if ! command -v omp >/dev/null 2>&1; then
      echo "omp is not on PATH." >&2
      exit 127
    fi

    workspace_json="$(herdr workspace list)"
    workspace_id="$(
      printf '%s\n' "$workspace_json" \
        | jq -r '.result.workspaces[]? | select(.focused == true) | .workspace_id' \
        | head -n 1
    )"

    if [ -z "$workspace_id" ]; then
      echo "No focused Herdr workspace found." >&2
      exit 1
    fi

    pane_json="$(herdr pane list)"
    cwd="$(
      printf '%s\n' "$pane_json" \
        | jq -r --arg workspace "$workspace_id" '.result.panes[]? | select(.workspace_id == $workspace and .focused == true) | .cwd' \
        | head -n 1
    )"
    if [ -z "$cwd" ]; then
      cwd="$(
        printf '%s\n' "$pane_json" \
          | jq -r --arg workspace "$workspace_id" '.result.panes[]? | select(.workspace_id == $workspace) | .cwd' \
          | head -n 1
      )"
    fi
    if [ -z "$cwd" ]; then
      cwd="$PWD"
    fi

    tab_label="''${HERDR_OMP_TAB_LABEL:-omp}"
    created="$(herdr tab create --workspace "$workspace_id" --cwd "$cwd" --label "$tab_label" --focus)"
    pane_id="$(printf '%s\n' "$created" | jq -r '.result.root_pane.pane_id')"

    cmd="omp"
    for arg in "$@"; do
      printf -v quoted '%q' "$arg"
      cmd="$cmd $quoted"
    done

    herdr pane rename "$pane_id" "$tab_label" >/dev/null
    herdr pane run "$pane_id" "$cmd" >/dev/null
  '';

  herdrOmpShortcut = pkgs.writeShellScriptBin "hot" ''
    exec ${herdrOmpTab}/bin/herdr-omp-tab "$@"
  '';
in
{
  config = lib.mkIf enabled {
    home.packages = [
      herdr
      pkgs.ttyd
      herdrPhoneAttach
      herdrPhoneServe
      herdrPhoneStatus
      herdrPhoneLogs
      herdrOmpTab
      herdrOmpShortcut
    ];

    systemd.user.services.herdr-phone = {
      Unit = {
        Description = "Herdr phone web terminal";
        After = [
          "network.target"
          "herdr-phone-server.service"
        ];
        Wants = [ "herdr-phone-server.service" ];
      };
      Service = {
        Environment = [
          "PATH=${scriptPath}"
        ];
        ExecStart = "${herdrPhoneTtyd}/bin/herdr-phone-ttyd";
        WorkingDirectory = config.home.homeDirectory;
        Restart = "always";
        RestartSec = 2;
      };
    };

    systemd.user.services.herdr-phone-server = {
      Unit = {
        Description = "Herdr phone session server";
        After = [ "network.target" ];
      };
      Service = {
        Environment = [
          "PATH=${scriptPath}"
          "HERDR_SESSION=${cfg.session}"
        ];
        ExecStart = "${herdr}/bin/herdr server";
        WorkingDirectory = config.home.homeDirectory;
        Restart = "always";
        RestartSec = 2;
      };
    };

    xdg.configFile."herdr/config.toml".text = ''
      onboarding = false

      [theme]
      name = "terminal"

      [keys]
      previous_workspace = "ctrl+shift+up"
      next_workspace = "ctrl+shift+down"
      previous_agent = "ctrl+up"
      next_agent = "ctrl+down"

      [[keys.command]]
      key = "prefix+shift+o"
      type = "shell"
      command = "${herdrOmpTab}/bin/herdr-omp-tab"
    '';
  };
}
