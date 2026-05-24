{ config, lib, ... }:

{
  config = lib.mkIf (config.dotfiles.noSleep || config.dotfiles.llm) {
    systemd.sleep.settings.Sleep = {
      AllowSuspend = false;
      AllowHibernation = false;
      AllowHybridSleep = false;
      AllowSuspendThenHibernate = false;
    };
  };
}
