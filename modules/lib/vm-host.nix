# Per-guest facts shared by a microvm.nix guest and the host module that runs it: both sides
# must agree on the tap name, the /30, the fixed MAC and the host state paths, or the guest
# boots without an address and the firewall chains name an interface that does not exist.
#
# `agent` predates this helper and keeps its own constants in modules/lib/agent-vm.nix; new
# guests pass a distinct `index` (the third IPv4 octet) so taps and subnets never collide.
{
  name,
  index,
  vsockCid ? null,
}:
assert index > 0 && index < 256;
let
  digits = "0123456789abcdef";
  hexByte =
    n: "${builtins.substring (n / 16) 1 digits}${builtins.substring (n - 16 * (n / 16)) 1 digits}";
  octet = toString index;
in
{
  inherit name vsockCid;
  tap = "vm-${name}";
  network = "10.77.${octet}.0/30";
  hostAddr = "10.77.${octet}.1";
  guestAddr = "10.77.${octet}.2";
  # Locally administered unicast; the third/fourth bytes mirror the guest address so the
  # guest's networkd MAC match is readable at a glance.
  mac = "02:00:0a:4d:${hexByte index}:02";
  stateDir = "/var/lib/${name}-vm";
  # Where microvm.nix links the guest toplevel the next boot would use.
  vmStateDir = "/var/lib/microvms/${name}";
}
