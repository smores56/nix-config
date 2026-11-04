# Root-owned Claude Code managed settings for the work Mac: every session (interactive, -p,
# background) runs Bash under Claude's Seatbelt sandbox with no unsandboxed retry, so no agent
# can read the sops identity or decrypted secrets, and only sudo can loosen it.
{
  lib,
  pkgs,
  ...
}:
let
  target = "/Library/Application Support/ClaudeCode/managed-settings.json";

  # @UT@ is the resolved per-user temp dir, known only at install time; sops-nix decrypts under
  # it in a generation-numbered dir, hence the glob.
  secretsDir = "@UT@/secrets.d";
  # Secrets Bash tools need: gh/git (PATs, signing keys) and the smortress ProxyCommand.
  allowedSecrets = [
    "github-personal-pat"
    "github-personal-signing-key"
    "github-work-pat"
    "github-work-signing-key"
    "cloudflare-access-ssh-token"
  ];
  denied = [
    "~/.config/sops"
    secretsDir
    "@UT@/piv"
  ];

  workRoots = [
    "~/code"
    "~/Blitzy"
  ];

  policy = {
    permissions.deny =
      # Read rules also become sandbox read-denies; the decrypted files are denied at their
      # resolved path below, so the ~/.config/sops-nix links git reads stay usable.
      [ "Read(~/.config/sops/**)" ]
      # Edit and Write run in-process, outside the sandbox: keep them off files an unsandboxed
      # shell or launchd would later execute.
      ++ map (p: "Edit(${p})") [
        "~/.zshrc"
        "~/.zshenv"
        "~/.zprofile"
        "~/.bashrc"
        "~/.bash_profile"
        "~/.profile"
        "~/.config/**"
        "~/.local/bin/**"
        "~/Library/LaunchAgents/**"
        "~/.claude/settings*.json"
        "~/.claude.json"
      ];
    sandbox = {
      enabled = true;
      allowUnsandboxedCommands = false;
      # Go TLS (gh, gcloud) needs trustd.
      enableWeakerNetworkIsolation = true;
      filesystem = {
        denyRead = denied;
        # Project hooks and MCP servers would run in a later unsandboxed session.
        denyWrite =
          denied
          ++ lib.concatMap (root: [
            "${root}/**/.claude/**"
            "${root}/**/.mcp.json"
          ]) workRoots;
        allowRead = map (n: "${secretsDir}/*/${n}") allowedSecrets;
        allowWrite = workRoots ++ [
          "~/.cache"
          "~/.local/state"
          "/private/tmp"
          "@UT@"
        ];
      };
      network = {
        allowedDomains = [ "*" ];
        allowUnixSockets = [
          "/nix/var/nix/daemon-socket/socket"
          "~/.ssh/piv-agent.sock"
          "~/.ssh/sudo-agent.sock"
        ];
      };
    };
  };

  template = pkgs.writeText "claude-managed-settings.json" (builtins.toJSON policy);

  install = pkgs.writeShellApplication {
    name = "claude-policy-install";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnused
    ];
    text = ''
      ut=$(realpath "$(/usr/bin/getconf DARWIN_USER_TEMP_DIR)")
      rendered=$(mktemp)
      trap 'rm -f "$rendered"' EXIT
      sed "s|@UT@|$ut|g" ${template} >"$rendered"
      if [ "''${1:-}" = --check ]; then
        cmp -s "$rendered" ${lib.escapeShellArg target}
        exit
      fi
      /usr/bin/sudo /bin/mkdir -p ${lib.escapeShellArg (builtins.dirOf target)}
      /usr/bin/sudo /usr/bin/install -m 0644 -o root -g wheel "$rendered" ${lib.escapeShellArg target}
      echo "installed ${target}; new Claude sessions pick it up"
    '';
  };
in
{
  home.packages = [ install ];

  home.activation.claudePolicyCheck = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if ! ${lib.getExe install} --check; then
      echo "claude-policy: ${target} is missing or stale; run claude-policy-install" >&2
    fi
  '';
}
