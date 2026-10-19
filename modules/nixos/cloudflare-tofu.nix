# State directory and non-secret inputs for the minimal Cloudflare OpenTofu
# config (see tofu/). OpenTofu itself runs manually via the cloudflare-plan /
# cloudflare-apply flake apps; nothing here applies automatically.
{
  config,
  lib,
  ...
}:
{
  config = lib.mkMerge [
    (lib.mkIf (builtins.elem "server" config.machine.profiles) {
      systemd.tmpfiles.rules = [
        "d /var/lib/cloudflare-tofu 0700 root root -"
      ];
    })

    # Account ID is not a secret; the API token stays in sops and is read by
    # the flake app at run time. Only required when alerting supplies it.
    (lib.mkIf (builtins.elem "server" config.machine.profiles && config.alerting.enable) {
      environment.etc."cloudflare-tofu/account-id".text = config.alerting.accountId;
    })
  ];
}
