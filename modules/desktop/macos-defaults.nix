{
  lib,
  pkgs,
  ...
}:
let
  shared = import ./shared-bindings.nix { inherit lib; };
  # macOS counts key repeat in 15 ms ticks; round, and never below one tick.
  ticks = ms: lib.max 1 (builtins.floor (ms / 15.0 + 0.5));
  # Ctrl+arrows and Ctrl+digits belong to AeroSpace: Mission Control (32, 34), App Exposé (33, 35),
  # moving between Spaces (79-82) and Switch to Desktop 1-9 (118-126) would otherwise answer first.
  windowManagerHotkeys = map toString (
    [
      32
      33
      34
      35
      79
      80
      81
      82
    ]
    ++ lib.range 118 126
  );
  configureHotkeys = pkgs.writeShellScript "macos-hotkeys" ''
    export SYSTEM_HOTKEYS=${
      lib.escapeShellArg (
        builtins.toJSON {
          enable = shared.screenshots.macos;
          disable = windowManagerHotkeys;
        }
      )
    }
    exec ${pkgs.python3}/bin/python3 -I ${./macos-hotkeys.py}
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
  # replace wholesale, so only the entries this configuration owns are rewritten.
  home.activation.configureSystemHotkeys = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run ${configureHotkeys}
  '';
}
