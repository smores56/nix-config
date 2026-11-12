# #509: the cluster serves Immich and Navidrome, so a rebuild must not start
# the host copies again. The data and the webProxy routes stay, so rollback is
# deleting this file and switching — not a restore.
#
# This is the narrow version of `clusterDataApps.enable`, which also clears the
# memory stack; flipping that one waits for the memory wrapper to move
# in-cluster.
{ lib, ... }:
{
  services.immich.enable = lib.mkForce false;
  services.navidrome.enable = lib.mkForce false;
}
