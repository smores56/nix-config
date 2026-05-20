{ config, lib, pkgs, ... }:
let
  cfg = config.dotfiles;

  openchamberVersion = "1.11.3";

  openchamber = pkgs.writeShellScriptBin "openchamber" ''
    exec ${pkgs.bun}/bin/bun x @openchamber/web@${openchamberVersion} "$@"
  '';

  openchamberServe = pkgs.writeShellScriptBin "openchamber-serve" ''
    set -e
    PASSPHRASE_FILE="${config.home.homeDirectory}/.config/openchamber/ui-password"
    if [ -f "$PASSPHRASE_FILE" ] && [ -s "$PASSPHRASE_FILE" ]; then
      IFS= read -r PASSPHRASE < "$PASSPHRASE_FILE"
      exec ${pkgs.bun}/bin/bun x @openchamber/web@${openchamberVersion} serve \
        --port 3000 \
        --host 0.0.0.0 \
        --ui-password "$PASSPHRASE" \
        --foreground
    else
      exec ${pkgs.bun}/bin/bun x @openchamber/web@${openchamberVersion} serve \
        --port 3000 \
        --host 0.0.0.0 \
        --foreground
    fi
  '';

  ocx = pkgs.writeShellScriptBin "ocx" ''
    exec ${pkgs.bun}/bin/bun x ocx@2.0.11 "$@"
  '';

  opencodeSettings = {
    "$schema" = "https://opencode.ai/config.json";
    model = "opencode-go/deepseek-v4-pro";
    small_model = "opencode-go/deepseek-v4-flash";
    plugin = [
      "opencode-plugin-openspec"
      "opencode-beads"
      "@tarquinen/opencode-smart-title"
      "opencode-snip"
    ];
    server = {
      hostname = "0.0.0.0";
      port = 4000;
    };
    provider.opencode-go = {
      name = "OpenCode Go";
    };

    provider.wafer = {
      npm = "@ai-sdk/openai-compatible";
      name = "Wafer";
      options = {
        baseURL = "https://pass.wafer.ai/v1";
        apiKey = "{env:WAFER_API_KEY}";
      };
      models = {
        "GLM-5.1" = {
          name = "GLM 5.1";
          limit = { context = 202752; output = 65536; };
        };
      };
    };
  };

  opencodeTui = {
    "$schema" = "https://opencode.ai/tui.json";
    keybinds.leader = "ctrl+a";
  };
in
{
  home.packages = with pkgs; [
    opencode
    beads
    snip
    ocx
    openchamber
  ];

  xdg.configFile."opencode/opencode.json" = {
    text = builtins.toJSON opencodeSettings;
  };

  xdg.configFile."opencode/tui.json" = {
    text = builtins.toJSON opencodeTui;
  };

  xdg.configFile."opencode/AGENTS.md" = {
    text = cfg.aiHints;
  };

  xdg.configFile."opencode/smart-title.jsonc" = {
    text = builtins.toJSON {
      model = "opencode-go/deepseek-v4-flash";
    };
  };

  home.activation.setupOcxWorkspace = {
    after = [ "linkGeneration" ];
    before = [ ];
    data = ''
      if [ -d "$HOME/.config/opencode/profiles/ws" ]; then
        echo "[ocx] Workspace profile configured"
      else
        echo "[ocx] Workspace profile not found"
      fi
    '';
  };

  systemd.user.services.opencode = lib.mkIf cfg.opencodeServe {
    Unit = {
      Description = "OpenCode Server";
      After = [ "network.target" ];
    };
    Service = {
      Environment = "PATH=${lib.makeBinPath [ pkgs.opencode ]}:${config.home.homeDirectory}/.nix-profile/bin";
      ExecStart = "${pkgs.opencode}/bin/opencode serve --port 4000";
      WorkingDirectory = config.home.homeDirectory;
      Restart = "always";
      RestartSec = 5;
    };
    Install = {
      WantedBy = [ "default.target" ];
    };
  };

  systemd.user.services.openchamber = lib.mkIf cfg.opencodeServe {
    Unit = {
      Description = "OpenChamber Web UI";
      After = [ "network.target" "opencode.service" ];
      BindsTo = [ "opencode.service" ];
    };
    Service = {
      Environment = [
        "PATH=${lib.makeBinPath [ pkgs.bun pkgs.nodejs ]}:${config.home.homeDirectory}/.nix-profile/bin"
        "OPENCODE_HOST=http://localhost:4000"
        "OPENCODE_SKIP_START=true"
      ];
      ExecStart = "${openchamberServe}/bin/openchamber-serve";
      WorkingDirectory = config.home.homeDirectory;
      Restart = "always";
      RestartSec = 5;
    };
    Install = {
      WantedBy = [ "default.target" ];
    };
  };
}
