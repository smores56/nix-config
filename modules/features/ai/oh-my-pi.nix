{ config, pkgs, ... }:
let
  cfg = config.dotfiles;

  ompSettingsJson = builtins.toJSON {
    defaultProvider = "smortress";
    inherit (cfg) defaultModel;
    packages = [
      "npm:tsx@4.21.0"
    ];
    compaction = {
      enabled = true;
      reserveTokens = 16384;
      keepRecentTokens = 12000;
    };
  };
in
{
  home.file = {
    ".omp/agent/extensions/caveman/index.ts".source = pkgs.fetchFromGitHub {
      owner = "v2nic";
      repo = "pi-caveman";
      rev = "2480692ffabddc3d1efec8eb822e664ff7e0e5ef";
      hash = "sha256-J9Kbvp6Ln3W8QIwCIzC6E6MjeyZqCU2ucYPSUrsmJg0=";
    } + "/extensions/caveman/index.ts";
    ".omp/agent/settings.json" = {
      text = ompSettingsJson;
      force = true;
    };
  };
}
