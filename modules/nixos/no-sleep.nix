{ config, lib, ... }:

{
  options.noSleep.enable = lib.mkEnableOption "disabling automatic suspend/sleep for an always-on host";

  config = lib.mkIf (config.noSleep.enable || config.llm.enable) {
    systemd.sleep.settings.Sleep = {
      AllowSuspend = false;
      AllowHibernation = false;
      AllowHybridSleep = false;
      AllowSuspendThenHibernate = false;
    };
  };
}
