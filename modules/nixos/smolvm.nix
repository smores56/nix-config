# SmolVM microVM runtime — system-level packages and udev rules.
# SmolVM's sudoers config pins exact binary paths; NixOS system profile
# provides stable paths at /run/current-system/sw/bin/.
# Run `scripts/setup-smolvm.sh` (in the camp repo) after building to configure sudoers.
{ pkgs, ... }:
{
  environment.systemPackages = [
    pkgs.firecracker
    pkgs.nftables
    pkgs.wget
    pkgs.gnutar
  ];

  # SmolVM expects /dev/kvm with group=kvm, mode=0660.
  # On standard distros `smolvm setup` writes this to /etc/udev/rules.d,
  # but NixOS has a read-only /etc — declare it here instead.
  services.udev.extraRules = ''
    KERNEL=="kvm", GROUP="kvm", MODE="0660", TAG+="uaccess"
  '';

  # Ensure the kvm group exists (NixOS creates it when virtualisation.libvirtd
  # is enabled, but SmolVM doesn't require libvirtd).
  users.groups.kvm = { };
}
