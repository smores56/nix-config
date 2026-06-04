{
  config,
  lib,
  ...
}:
let
  cfg = config.dotfiles.pinano;
  homeDir = config.home.homeDirectory;
in
{
  options.dotfiles.pinano = {
    enable = lib.mkEnableOption "pinano AI coding assistant" // {
      default = true;
    };
  };

  config = lib.mkIf cfg.enable {
    home.activation.installPinano = {
      after = [ "linkGeneration" ];
      before = [ ];
      data = ''
        if command -v pinano >/dev/null 2>&1; then
          echo "[pinano] Already installed"
        else
          echo "[pinano] Installing pinano from github:rmst/pinano"
          export PATH="${homeDir}/.bun/bin:$PATH"
          if command -v bun >/dev/null 2>&1; then
            cd "$(mktemp -d)"
            bun init -y >/dev/null 2>&1
            bun add "github:rmst/pinano" >/dev/null 2>&1
            ln -sf "$(pwd)/node_modules/.bin/pinano" "${homeDir}/.bun/bin/pinano"
            echo "[pinano] Installed pinano to ${homeDir}/.bun/bin/pinano"
          elif command -v npm >/dev/null 2>&1; then
            npm install -g github:rmst/pinano >/dev/null 2>&1
            echo "[pinano] Installed pinano via npm"
          else
            echo "[pinano] Neither bun nor npm found, cannot install pinano" >&2
          fi
        fi
      '';
    };
  };
}
