# Where a sops secret's file lives: the declaring config's own path (home-manager
# sops on Darwin), else the sops-nix location on NixOS.
config: name: config.sops.secrets.${name}.path or "/run/secrets/${name}"
