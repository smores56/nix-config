{
  lib,
  pkgs,
  ...
}:
let
  shared = import ./shared-bindings.nix { inherit lib; };
  # macOS counts key repeat in 15 ms ticks; round, and never below one tick.
  ticks = ms: lib.max 1 (builtins.floor (ms / 15.0 + 0.5));
  configureScreenshots = pkgs.writeShellScript "macos-screenshot" ''
    export SCREENSHOT_SHORTCUTS=${lib.escapeShellArg (builtins.toJSON shared.screenshots.macos)}
    exec ${pkgs.python3}/bin/python3 -I ${./macos-screenshot.py}
  '';
in
{
  targets.darwin.defaults.NSGlobalDomain = {
    InitialKeyRepeat = ticks shared.input.repeatDelayMs;
    KeyRepeat = ticks (1000.0 / shared.input.repeatRate);
    "com.apple.swipescrolldirection" = shared.input.naturalScroll;
    "com.apple.scrollwheel.scaling" = shared.input.scrollFactor;
  };

  # AppleSymbolicHotKeys holds every system shortcut in one dict, which `defaults import` would
  # replace wholesale, so only the missing screenshot entries are added.
  home.activation.configureScreenshotKeys = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run ${configureScreenshots}
  '';
}
