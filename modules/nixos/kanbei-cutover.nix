# NixOS-plane assertions for the #509 cutover. The option lives in
# modules/kanbei-split.nix (shared with home-manager); this module adds the checks
# that make a flipped switch fail evaluation instead of leaving a half-retired host.
{ config, lib, ... }:
let
  cutover = config.kanbeiSplit.cutover.enable;
  vms = config.microvm.vms or { };
  units = config.systemd.services;
in
{
  imports = [ ../kanbei-split.nix ];

  assertions = [
    {
      assertion = !cutover || !(vms ? agent);
      message = "kanbeiSplit.cutover: microvm.vms.agent must be gone; nanobot runs in the cluster, not a host guest";
    }
    {
      assertion = !cutover || !(units ? open-webui);
      message = "kanbeiSplit.cutover: the Open WebUI unit must be gone";
    }
    {
      assertion = !cutover || !(units ? files-mcp);
      message = "kanbeiSplit.cutover: the files-mcp unit must be gone";
    }
    {
      assertion = !cutover || (!(units ? agent-vm-prep) && !(units ? agent-vm-net));
      message = "kanbeiSplit.cutover: no agent-VM host unit may survive the cutover";
    }
    {
      assertion =
        !cutover || !(lib.any (n: lib.hasPrefix "agent-vm-" n) (lib.attrNames config.systemd.sockets));
      message = "kanbeiSplit.cutover: the agent-VM ingress/broker sockets must be gone";
    }
    {
      # The platform CronJob (homelabs-platform) owns the mirror and its read-only PAT.
      # This guards the deletion: a reintroduced nix-config module would fail here.
      assertion = !(units ? github-mirror) && !(units ? github-metadata-full);
      message = "GitHub mirroring moved to the homelabs-platform CronJob; do not re-add a nix-config unit";
    }
    {
      assertion = !((config.sops.secrets or { }) ? github-repo-pat);
      message = "the GitHub mirror PAT belongs to homelabs-platform; do not declare github-repo-pat here";
    }
  ];
}
