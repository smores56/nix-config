# Cross-host user secrets, decrypted from `secrets/common.yaml`. Every NixOS
# host that imports this module is an age recipient for that file and can read
# all of it, so host-only material belongs in `secrets/<host>.yaml` instead.
{
  config,
  lib,
  ...
}:
{
  # A host's age identity is its SSH host key, delivered out of band (the
  # installer copies `secrets/hosts/<host>/` into `/etc/ssh`). smortress uses
  # sshd's key; smorespro runs no sshd and the key exists only for sops.
  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

  sops.secrets = {
    # maki's hosted-inference key. The fish init exports it from this path, so
    # the user must be able to read it on every personal host.
    neuralwatt-api-key = {
      sopsFile = ../../secrets/common.yaml;
      owner = config.machine.username;
      mode = "0400";
      # Only smortress runs the memory gateway, and it reads the credential once
      # at start; naming a unit other hosts lack would fail their activation.
      restartUnits = lib.optional (config.systemd.services ? memory-llm-proxy) "memory-llm-proxy.service";
    };
  };
}
