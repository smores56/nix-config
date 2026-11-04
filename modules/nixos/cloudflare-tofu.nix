# State directory and non-secret inputs for the Cloudflare OpenTofu config (tofu/).
# Applied manually via the cloudflare-plan / cloudflare-apply flake apps.
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

    # Not a secret; the API token stays in sops.
    (lib.mkIf (builtins.elem "server" config.machine.profiles) {
      environment.etc."cloudflare-tofu/account-id".text = config.alerting.accountId;
    })
  ];
}
