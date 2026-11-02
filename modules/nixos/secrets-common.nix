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
    # The personal account's bundle: an owner-scoped fine-grained PAT for gh,
    # HTTPS git and Maki, and the commit-signing key git uses for every
    # non-work repo. Readable by the user because git and Maki run as that
    # uid; the sandbox binds both. The work bundle lives only on the work Mac
    # (modules/hosts/smoreswork/sops.nix), so NixOS hosts hold no work
    # credential.
    github-personal-pat = {
      sopsFile = ../../secrets/common.yaml;
      owner = config.machine.username;
      mode = "0400";
    };
    github-personal-signing-key = {
      sopsFile = ../../secrets/common.yaml;
      owner = config.machine.username;
      mode = "0400";
    };

    # Scoped Immich API key for the sandboxed agent (asset read/upload, album
    # read/create). The sandbox launcher reads it as the user and binds it inside
    # the boundary at /run/agent/immich-key; declaring it here is what makes
    # sops-nix materialise /run/secrets/immich-agent-api-key at all.
    immich-agent-api-key = {
      sopsFile = ../../secrets/common.yaml;
      owner = config.machine.username;
      mode = "0400";
    };

    # Bearer token for the memory MCP listener. Every personal host runs the
    # shim/CLI that presents it, so it lives in common.yaml and the user owns
    # the 0400 file.
    memory-mcp-token = {
      sopsFile = ../../secrets/common.yaml;
      owner = config.machine.username;
      mode = "0400";
    };

    # maki's hosted-inference key. The fish init exports it from this path, so
    # the user must be able to read it on every personal host.
    neuralwatt-api-key = {
      sopsFile = ../../secrets/common.yaml;
      owner = config.machine.username;
      mode = "0400";
      # Only smortress runs the memory gateway and Open WebUI, and both read the
      # credential at start; naming a unit other hosts lack would fail their
      # activation.
      restartUnits =
        lib.optional (config.systemd.services ? memory-llm-proxy) "memory-llm-proxy.service"
        ++ lib.optional (config.systemd.services ? open-webui) "open-webui.service";
    };

    # SHA-512 crypt hash of the account password. `neededForUsers` decrypts it
    # into /run/secrets-for-users before the users activation, which is the only
    # stage that can read hashedPasswordFile. Root-owned by assertion in
    # sops-nix; the plaintext password exists only off-site.
    smores-password-hash = {
      sopsFile = ../../secrets/common.yaml;
      neededForUsers = true;
    };

    # Maki's web search key. The fish init exports it as TINYFISH_API_KEY on
    # every NixOS host, so the user must be able to read it.
    tinyfish-api-key = {
      sopsFile = ../../secrets/common.yaml;
      owner = config.machine.username;
      mode = "0400";
    };
  };

  # One account, declared rather than mutable: the sops hash is re-applied on
  # every activation and any account not declared here is removed. This is what
  # makes the password survive reinstalls instead of being a one-time `passwd`.
  users.mutableUsers = false;
  users.users.${config.machine.username}.hashedPasswordFile =
    config.sops.secrets.smores-password-hash.path;
}
