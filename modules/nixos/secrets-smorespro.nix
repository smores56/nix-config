# Host-only secrets for smorespro, decrypted by sops-nix at activation from
# `secrets/smorespro.yaml`. Declared per host because the age recipients are
# host-scoped: only smorespro's SSH host key decrypts that file.
{
  config,
  lib,
  ...
}:
{
  config = lib.mkIf (config.networking.hostName == "smorespro") {
    sops.secrets.cloudflare-access-ssh-token = {
      sopsFile = ../../secrets/smorespro.yaml;
      owner = config.machine.username;
      mode = "0400";
    };
  };
}
