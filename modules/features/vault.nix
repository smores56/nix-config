# `v [cmd]`: run one tool as the `vault` user, in the vault store.
#
# The store is owned by the `vault` user and the human's uid has no access to it
# at rest (see modules/nixos/vault-sync.nix). Nothing is mounted and no uid is
# mapped: the tool itself runs as `vault`, so every path it opens carries the
# store's owner-only permissions, and no view of the tree outlives the process.
#
# The `vault` binary lives in the system profile (modules/nixos/vault-sync.nix)
# so both this abbreviation and the work Mac's SSH command reach it by a stable
# path; `-H` keeps tool config and state in vault's own home.
_: {
  # Absolute sudo: a `sudo` planted earlier on PATH (an rc file, ~/.local/bin)
  # must never be the one that gets the YubiKey touch.
  user.shellAbbrs.v = "/run/wrappers/bin/sudo -H -u vault /run/current-system/sw/bin/vault";
}
