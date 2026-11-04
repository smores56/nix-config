# Admin sops decryption: the age identity lives off every host in a passphrase-encrypted file.
# Shells hand sops the unwrapped identity through a command, so no plaintext keys.txt exists.
{
  lib,
  pkgs,
  ...
}:

let
  # The wrapper's stdout must be only the identity; `age` prompts on the tty, keeping the passphrase out of argv, env and the store.
  sopsAgeKey = pkgs.writeShellApplication {
    name = "sops-age-key";
    text = ''
      # sops folds stderr into its own error, so also tell the operator why on the tty.
      fail() {
        echo "sops-age-key: $*" >&2
        { echo "sops-age-key: $*" > /dev/tty; } 2>/dev/null || true
        exit 1
      }

      # sops loads this default even when SOPS_AGE_KEY_CMD is set, so a leftover plaintext identity would bypass the passphrase.
      legacy="''${XDG_CONFIG_HOME:-$HOME/.config}/sops/age/keys.txt"
      if [ -e "$legacy" ]; then
        fail "remove the retired plaintext identity $legacy"
      fi

      key="''${XDG_CONFIG_HOME:-$HOME/.config}/sops/keys.age"
      # Checked so the error names the file to provision, not age's generic passphrase prompt.
      if [ ! -r "$key" ]; then
        fail "$key is missing or unreadable; provision the passphrase-wrapped admin age identity there"
      fi
      exec ${pkgs.age}/bin/age --decrypt "$key"
    '';
  };
in
{
  # age is the wrapper's dependency; sops must be present in a fresh shell.
  home.packages = [
    pkgs.age
    pkgs.sops
  ];

  home.sessionVariables.SOPS_AGE_KEY_CMD = lib.getExe sopsAgeKey;
}
