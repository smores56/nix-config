# Admin sops decryption: the age identity that edits and re-encrypts secrets
# lives off every host, wrapped in a passphrase-encrypted file. Shells hand
# sops the unwrapped identity through a command instead of a key on disk, so
# no plaintext keys.txt exists to leak, back up, or provision onto a machine.
{
  lib,
  pkgs,
  ...
}:

let
  # sops runs SOPS_AGE_KEY_CMD itself, so the wrapper's stdout must be only the
  # identity. `age` prompts on the tty and keeps the passphrase out of argv,
  # environment, and the store.
  sopsAgeKey = pkgs.writeShellApplication {
    name = "sops-age-key";
    text = ''
      key="$HOME/.config/sops/keys.age"
      # Checked here rather than letting age fail, so the error names the file
      # that has to be provisioned instead of age's generic passphrase prompt.
      if [ ! -r "$key" ]; then
        echo "sops-age-key: $key is missing or unreadable; provision the passphrase-wrapped admin age identity there" >&2
        exit 1
      fi
      exec ${pkgs.age}/bin/age --decrypt "$key"
    '';
  };
in
{
  # age is the wrapper's dependency; sops itself must be present in a fresh
  # shell, since interactive hosts no longer have a decryption key baked in.
  home.packages = [
    pkgs.age
    pkgs.sops
  ];

  home.sessionVariables.SOPS_AGE_KEY_CMD = lib.getExe sopsAgeKey;
}
