{ config, lib, pkgs, ... }:
let
  cfg = config.dotfiles;

  ocxArch = if pkgs.stdenv.isDarwin then "darwin-arm64" else "linux-x64";
  ocxHash = if pkgs.stdenv.isDarwin then
    "sha256-9c9d5e7102c3e4ea076540900c84ebfde7acf449636b45f1d5cc40d0fcff0492"
  else
    "sha256-4a99b0487f8ad2f8ce0879393cdb6ba54345d87624b9259e8011738a70d70f54";

  ocx = pkgs.stdenv.mkDerivation rec {
    pname = "ocx";
    version = "2.0.11";
    src = pkgs.fetchurl {
      url = "https://github.com/kdcokenny/ocx/releases/download/v${version}/ocx-${ocxArch}";
      hash = ocxHash;
    };
    dontUnpack = true;
    installPhase = ''
      mkdir -p $out/bin
      cp $src $out/bin/ocx
      chmod +x $out/bin/ocx
    '';
  };

  openportal = pkgs.writeShellScriptBin "openportal" ''
    exec ${pkgs.bun}/bin/bun x openportal@0.1.32 "$@"
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

  programs.fish.shellAbbrs.o = "opencode attach http://smortress:4000";

  home.activation.setupOcxWorkspace = {
    after = [ "linkGeneration" ];
    before = [ ];
    data = ''
      if [ ! -d "$HOME/.config/opencode/profiles/ws" ]; then
        echo "Setting up OCX workspace profile..."
        ${ocx}/bin/ocx init --global
        ${ocx}/bin/ocx profile add ws --source tweak/p-1vp4xoqv --from https://tweakoc.com/r --global
        echo "OCX workspace profile setup complete."
      fi
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
