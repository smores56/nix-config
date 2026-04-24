{ pkgs, ... }:
{
  programs.ghostty = {
    enable = true;
    # Prefer local installs
    package = pkgs.nil;
    settings = {
      macos-option-as-alt = true;
      keybind = [
        "alt+up=unbind"
        "alt+down=unbind"
        "alt+left=unbind"
        "alt+right=unbind"
      ];
    };
  };
}
