{ ... }:
{
  stylix.targets.swaylock.enable = true;

  programs.swaylock = {
    enable = true;

    settings = {
      font-size = 24;
      indicator-idle-visible = false;
      indicator-radius = 100;
      show-failed-attempts = true;
    };
  };
}
