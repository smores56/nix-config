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

    # Maki's web search key. The fish init exports it as TINYFISH_API_KEY on
    # every NixOS host, so the user must be able to read it.
    tinyfish-api-key = {
      sopsFile = ../../secrets/common.yaml;
      owner = config.machine.username;
      mode = "0400";
    };

    # SHA-512 crypt hash of the account password. `neededForUsers` decrypts it
    # into /run/secrets-for-users before the users activation, which is the only
    # stage that can read hashedPasswordFile. Root-owned by assertion in
    # sops-nix; the plaintext password exists only off-site.
    # Owner-scoped fine-grained PATs for Maki (and HTTPS git when the agent is
    # not around). Readable by the user because Maki runs as that uid; the
    # sandbox's credential helper selects by repository owner. No key
    # management: SSH/signing stay on the FIDO2 path.
    github-personal-pat = {
      sopsFile = ../../secrets/common.yaml;
      owner = config.machine.username;
      mode = "0400";
    };
    github-work-pat = {
      sopsFile = ../../secrets/common.yaml;
      owner = config.machine.username;
      mode = "0400";
    };

    smores-password-hash = {
      sopsFile = ../../secrets/common.yaml;
      neededForUsers = true;
    };
  };

  # One account, declared rather than mutable: the sops hash is re-applied on
  # every activation and any account not declared here is removed. This is what
  # makes the password survive reinstalls instead of being a one-time `passwd`.
  users.mutableUsers = false;
  users.users.${config.machine.username}.hashedPasswordFile =
    config.sops.secrets.smores-password-hash.path;
}
