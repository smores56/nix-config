# Host-only secrets for smorespro, decrypted by sops-nix at activation from
# `secrets/smorespro.yaml`. Declared per host because the age recipients are
# host-scoped: only smorespro's SSH host key decrypts that file.
{ config, ... }:
{
  sops.defaultSopsFile = ../../../secrets/smorespro.yaml;
  sops.secrets.cloudflare-access-ssh-token = {
    owner = config.machine.username;
    mode = "0400";
  };
}
