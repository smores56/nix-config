{
  config,
  lib,
  pkgs,
  aiProviders,
  ...
}:
let
  ports = import ../ports.nix;

  models = import ../lib/llama-cpp-models.nix { inherit pkgs; };

in
{
  # Inert while the kanbei guest owns the GPU (modules/nixos/kanbei-vm.nix) or the
  # host is built without one; T9 deletes the file.
  config = lib.mkIf (config.machine.gpu && !(config.kanbeiVm.enable or false)) {
    # The host serves the model around the clock, so it must never suspend.
    systemd.sleep.settings.Sleep = {
      AllowSuspend = false;
      AllowHibernation = false;
      AllowHybridSleep = false;
      AllowSuspendThenHibernate = false;
    };

    services.llama-cpp = {
      enable = true;
      package = models.llama-cpp;
      settings = models.commonSettings // {
        # Loopback only: the Cloudflare Tunnel proxies llm.<domain> to it, and
        # the tunnel's Access app is the only way in.
        host = "127.0.0.1";
        port = ports.llm;
        alias = aiProviders.smortress.models.qwen38.id;
        model = models.mainModel;
        ctx-size = 200192;
        cont-batching = true;
        spec-type = "draft-dflash";
        spec-draft-n-max = 3;
        model-draft = models.draftModel;
        n-gpu-layers-draft = 99;
        reasoning-format = "deepseek";
        # Qwen3.8 model-card sampling (thinking mode; non-thinking: 0.7/0.8,
        # presence-penalty 1.5)
        temp = 1.0;
        top-k = 20;
        top-p = 0.95;
        min-p = 0.0;
        repeat-penalty = 1.0;
      };
    };

    # Only extends the unit the module creates; without the gate a disabled
    # `services.llama-cpp` leaves a unit with settings and no ExecStart behind.
    systemd.services.llama-cpp = lib.mkIf config.services.llama-cpp.enable {
      requires = [ "nvidia-uvm.service" ];
      after = [ "nvidia-uvm.service" ];
      restartIfChanged = false;
      serviceConfig.TimeoutStartSec = "1h";
    };
  };
}
