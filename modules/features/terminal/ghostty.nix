{ ... }:
{
  programs.ghostty = {
    enable = true;
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
