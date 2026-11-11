# The #509 cutover switch, shared by both planes so a NixOS host and a home config
# read the same value. Default off: every legacy service keeps running exactly as
# before. Turning it on retires the agent microVM (nanobot/Letta/Open WebUI), the
# files-mcp listener and the laptop chat proxies; the module files stay until the
# follow-up deletion commit (docs/kanbei-split.md, "Retirement table").
{ lib, ... }:
{
  options.kanbeiSplit.cutover.enable = lib.mkEnableOption ''
    the #509 retirement cutover: no agent microVM, Letta, Open WebUI, files-mcp or
    laptop chat proxy on the host. Flip only after the cluster serves the assistant
    and the private-data plane; see docs/manual-steps.md ("Kanbei cutover").
  '';
}
