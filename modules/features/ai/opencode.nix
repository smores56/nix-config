{ config, lib, pkgs, ... }:
let
  cfg = config.dotfiles;

  openportal = pkgs.writeShellScriptBin "openportal" ''
    exec ${pkgs.bun}/bin/bun x openportal@0.1.32 "$@"
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
      port = 4096;
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
      echo "Setting up OCX workspace profile..."
      
      # Initialize ocx if not already done
      if [ ! -f "$HOME/.config/opencode/ocx.jsonc" ]; then
        echo "[ocx] Initializing ocx..."
        time ${ocx}/bin/ocx init --global
      else
        echo "[ocx] ocx.jsonc exists, skipping init"
      fi
      
      # Add tweak registry if not configured
      echo "[ocx] Checking for tweak registry..."
      if ! timeout 5 ${ocx}/bin/ocx registry list --global 2>&1 | grep -q "tweak"; then
        echo "[ocx] Adding tweak registry (may take 15+ seconds on slow networks)..."
        time timeout 30 ${ocx}/bin/ocx registry add https://tweak.ocx.dev/registry --name tweak --global || echo "[ocx] Warning: registry add timed out or failed, continuing anyway..."
      else
        echo "[ocx] tweak registry already configured"
      fi
      
      # Add workspace profile if not exists
      if [ ! -d "$HOME/.config/opencode/profiles/ws" ]; then
        echo "[ocx] Adding workspace profile..."
        time timeout 30 ${ocx}/bin/ocx profile add ws --source tweak/p-1vp4xoqv --global || echo "[ocx] Warning: profile add timed out or failed, continuing anyway..."
      else
        echo "[ocx] workspace profile already exists"
      fi
      
      echo "OCX workspace profile setup complete."
    '';
  };

  systemd.user.services.openportal = lib.mkIf cfg.opencodeServe {
    Unit = {
      Description = "OpenCode Portal (Web UI + Server)";
      After = [ "network.target" ];
    };
    Service = {
      Environment = "PATH=${lib.makeBinPath [ pkgs.bun pkgs.opencode ]}:$PATH";
      ExecStart = "${openportal}/bin/openportal --hostname 0.0.0.0 --opencode-port 4000 --port 3000";
      WorkingDirectory = config.home.homeDirectory;
      Restart = "always";
      RestartSec = 5;
    };
    Install = {
      WantedBy = [ "default.target" ];
    };
  };
}
