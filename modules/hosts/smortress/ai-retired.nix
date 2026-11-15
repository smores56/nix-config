# #660 retires the AI plane: the data plane moves to Ubuntu, the kanbei guest's
# state was never migrated, and its package cannot be rebuilt (the deno
# fixed-output derivation hashes differently on every machine). `machine.gpu`
# off keeps `nvidia.nix` and `llm.nix` inert; with `kanbeiVm.enable = false`
# that is the pre-cutover pairing, so the 3090 sits idle instead of loading an
# unsigned module under Secure Boot. Restoring the guest is flipping the two
# flags in `default.nix`; deleting this file and those modules is the cleanup
# that follows.
{ lib, ... }:
{
  machine.gpu = false;
}
