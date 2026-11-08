# smorespro: Intel laptop, niri desktop with a fingerprint reader.
{
  system = "x86_64-linux";
  username = "smores";
  nixos = true;
  home = true;

  profiles = [
    ../../profiles/cli.nix
    ../../profiles/user-base.nix
    ../../profiles/ai-tools.nix
    ../../profiles/maki.nix
    ../../profiles/linux-desktop.nix
  ];
  nixosModules = [
    ./boot.nix
    ./greeter.nix
    ./fprintd.nix
    ./nymvpn.nix
    ./secrets.nix
    ../../nixos/todo-daemon.nix
  ];
  homeModules = [
    ../../features/chat-proxy.nix
    ../../features/todo.nix
  ];
  user = {
    shellAbbrs = {
      nv = "sudo nym-vpnc";
      nvc = "sudo nym-vpnc connect --wait";
      nvd = "sudo nym-vpnc disconnect --wait";
    };
  };

  nixosOptions = {
    # YubiKey sudo without an sshd: pam_rssh dials the local fido2-agent.
    sudoKey.enable = true;
    vaultSync.device = "smorespro";
  };
}
