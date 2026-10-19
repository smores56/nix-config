# Proton Pass is the single source of truth for the user's SSH identities:
# pass-cli's agent serves the vault's keys over SSH_AUTH_SOCK, so private keys
# never sit on disk (only their `.pub` files do, fetched by `ssh-pub-keys` in
# ssh-keys.nix — git's `user.signingkey` and `allowed_signers` reference
# files). This replaces the old file-backed
# ssh-agent and its `load-ssh-keys` helper.
_:

let
  # `fs` keeps the session's local encryption key in a file under the session
  # dir instead of the kernel keyring, which is wiped on reboot (and absent on
  # a headless host) — so one login survives reboots. The agent service does
  # not inherit shell variables, so it is set on the service too.
  keyProvider = "fs";
in
{
  services.proton-pass-agent.enable = true;
  home.sessionVariables.PROTON_PASS_KEY_PROVIDER = keyProvider;

  # The user manager starts this before the network is up, so pass-cli's first
  # vault lookups fail. The default start rate limiting gives up after 5 tries
  # in 10s (start-limit-hit), leaving the agent dead until a manual restart;
  # retry indefinitely instead so it recovers on its own once DNS works.
  systemd.user.services.proton-pass-agent = {
    Unit.StartLimitIntervalSec = 0;
    Service = {
      RestartSec = 5;
      Environment = [ "PROTON_PASS_KEY_PROVIDER=${keyProvider}" ];
    };
  };

  launchd.agents.proton-pass-agent.config.EnvironmentVariables = {
    PROTON_PASS_KEY_PROVIDER = keyProvider;
  };
}
