# Cross-host user secrets, decrypted from `secrets/common.yaml`. Every NixOS
# host that imports this module is an age recipient for that file and can read
# all of it, so host-only material belongs in `secrets/<host>.yaml` instead.
{
  config,
  lib,
  ...
}:
let
  # Hosts set their own `sops.defaultSopsFile`, so common secrets name theirs.
  userOwned = {
    sopsFile = ../../secrets/common.yaml;
    owner = config.machine.username;
    mode = "0400";
  };
in
{
  # A host's age identity is its SSH host key, delivered out of band (the
  # installer copies `secrets/hosts/<host>/` into `/etc/ssh`). smortress uses
  # sshd's key; smorespro runs no sshd and the key exists only for sops.
  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

  sops.secrets = {
    # Personal bundle: owner-scoped PAT for gh/HTTPS git/Maki and the commit-signing key
    # for non-work repos. User-readable because git and Maki run as that uid. The work
    # bundle lives only on the work Mac (modules/hosts/smoreswork/sops.nix).
    github-personal-pat = userOwned;
    github-personal-signing-key = userOwned;

    # Handed into both agent VMs (agentVm.secrets on Linux, handIn on the Mac) for calibredb
    # against the Content server; the server itself reads it on smortress.
    calibre-password = userOwned;

    # Every personal host's shim/CLI presents it, so it lives in common.yaml. Where the
    # listener runs, `memory` needs read access or every call returns 503.
    memory-mcp-token = userOwned // {
      group = if config.systemd.services ? memory-mcp then "memory" else "users";
      mode = "0440";
      # Open WebUI embeds the token, so it must restart with the listener or calls 401.
      restartUnits =
        lib.optional (config.systemd.services ? memory-mcp) "memory-mcp.service"
        ++ lib.optional (config.systemd.services ? open-webui) "open-webui.service";
    };

    # maki's hosted-inference key. The fish init exports it from this path, so
    # the user must be able to read it on every personal host.
    neuralwatt-api-key = userOwned // {
      # Only smortress runs the memory gateway and Open WebUI, and both read the
      # credential at start; naming a unit other hosts lack would fail their
      # activation.
      restartUnits =
        lib.optional (config.systemd.services ? memory-llm-proxy) "memory-llm-proxy.service"
        ++ lib.optional (config.systemd.services ? open-webui) "open-webui.service";
    };

    # `neededForUsers` decrypts into /run/secrets-for-users before users activation, the
    # only stage that can read hashedPasswordFile; sops-nix requires it root-owned.
    smores-password-hash = {
      inherit (userOwned) sopsFile;
      neededForUsers = true;
    };

    # Maki's web search key. The fish init exports it as TINYFISH_API_KEY on
    # every NixOS host, so the user must be able to read it.
    tinyfish-api-key = userOwned;
  };

  # Declared, not mutable: the hash is re-applied every activation and undeclared
  # accounts are removed, so the password survives reinstalls.
  users.mutableUsers = false;
  users.users.${config.machine.username}.hashedPasswordFile =
    config.sops.secrets.smores-password-hash.path;
}
