{
  lib,
  pkgs,
  ...
}:
let
  shared = import ./shared-bindings.nix { inherit lib; };
  configure = pkgs.writeShellScript "macos-screenshot" ''
    export SCREENSHOT_SHORTCUT=${lib.escapeShellArg (builtins.toJSON shared.screenshots.macos)}
    exec ${pkgs.python3}/bin/python3 -I ${./macos-screenshot.py}
  '';
in
{
  home.activation.configureScreenshotKey = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run ${configure}
  '';
}
