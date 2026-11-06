# Shared facts about the Linux agent VM and its launcher, used by the host module
# (modules/nixos/agent-vm.nix), the home launcher (modules/features/agent-vm/linux.nix) and the
# forced-SSH entry (modules/nixos/ssh.nix).
{ pkgs, lib }:
let
  self = {
    name = "agent";
    unit = "microvm@agent.service";
    tap = "vm-agent";
    hostAddr = "10.77.0.1";
    guestAddr = "10.77.0.2";
    stateDir = "/var/lib/agent-vm";
    # Secrets the launcher promotes into the session environment (VAR|guest path).
    secretEnv = [
      "GH_TOKEN|/run/secrets/github-personal-pat"
      "NEURALWATT_API_KEY|/run/secrets/neuralwatt-api-key"
      "TINYFISH_API_KEY|/run/secrets/tinyfish-api-key"
      "IMMICH_API_KEY|/run/secrets/immich-agent-api-key"
    ];

    launcher =
      user:
      pkgs.writeShellApplication {
        name = "agent-sandbox";
        runtimeInputs = [
          pkgs.openssh
          pkgs.coreutils
          pkgs.systemd
        ];
        text =
          let
            values = {
              inherit user;
              inherit (self) guestAddr stateDir unit;
            };
          in
          builtins.replaceStrings (map (n: "@${n}@") (lib.attrNames values) ++ [ "@secretEnv@" ]) (
            map lib.escapeShellArg (lib.attrValues values) ++ [ (lib.escapeShellArgs self.secretEnv) ]
          ) (builtins.readFile ./agent-vm-linux.sh);
      };

    # The forced command for the personal signing key (modules/nixos/ssh.nix): a laptop agent's
    # SSH into this host lands in this host's guest, never a host shell.
    agentSsh =
      user:
      pkgs.writeShellApplication {
        name = "agent-ssh";
        text = ''
          if [ -n "''${SSH_ORIGINAL_COMMAND:-}" ]; then
            exec ${self.launcher user}/bin/agent-sandbox bash -c "$SSH_ORIGINAL_COMMAND"
          fi
          exec ${self.launcher user}/bin/agent-sandbox bash -i
        '';
      };

    # sshd execs the login shell with -c <forced command>; detect that and skip fish's user config.
    # The per-key command= does not suppress ~/.ssh/rc, so PermitUserRC no is also required.
    agentLoginShell =
      user:
      (pkgs.writeShellApplication {
        name = "agent-login-shell";
        runtimeInputs = [ pkgs.fish ];
        text = ''
          if [ "$#" -ge 2 ] && [ "$1" = "-c" ] && [ "$2" = "${self.agentSsh user}/bin/agent-ssh" ]; then
            exec ${pkgs.fish}/bin/fish --no-config "$@"
          fi
          exec ${pkgs.fish}/bin/fish "$@"
        '';
      })
      // {
        # NixOS users.users.<name>.shell requires a shell package with shellPath.
        shellPath = "/bin/agent-login-shell";
      };
  };
in
self
