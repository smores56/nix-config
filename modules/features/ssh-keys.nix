# Key files on disk read by ssh (`IdentityFile`), git signing and signature verification. Public
# halves are committed in modules/lib/yubikey-keys.nix so a fresh machine needs no vault round
# trip; private halves stay on the YubiKeys.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.user;
  expandHome = lib.replaceStrings [ "~" ] [ "$HOME" ];

  yubikeyKeys = import ../lib/yubikey-keys.nix;
  yubikeyIdentities = map (k: {
    key = "~/.config/ssh-sk/${k.key}";
    inherit (k) pubkey;
  }) yubikeyKeys.piv;

  pubkeys = yubikeyIdentities;

  # Commit-signing keys from sops, trusted on every host for their own account only.
  signingKeys = import ../lib/signing-keys.nix;
  signingPrincipals = [
    {
      inherit (cfg) email;
      pubkey = signingKeys.personal;
    }
    {
      inherit (cfg.work) email;
      pubkey = signingKeys.work;
    }
  ];
  allowedSigners = "~/.config/ssh/allowed_signers";

  # Signatures verify only against the two account keys, each for its own principal.
  allowedSignersWriter = pkgs.writeShellApplication {
    name = "ssh-allowed-signers";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      out=${expandHome allowedSigners}
      # No config directory yet (fresh host) means no keys to verify against.
      mkdir -p "$(dirname "$out")" 2>/dev/null || exit 0
      chmod 700 "$(dirname "$out")" 2>/dev/null || true
      tmp=$(mktemp "$out.XXXXXX")
      {
        ${lib.concatMapStrings (i: ''
          printf '%s namespaces="git" %s\n' ${lib.escapeShellArg i.email} ${lib.escapeShellArg i.pubkey}
        '') signingPrincipals}
      } >"$tmp"
      mv "$tmp" "$out"
    '';
  };

  # Declarative: a changed key in Nix replaces the file at the next activation. Failures are
  # ignored (activation may precede a writable ~/.ssh); bootstrap surfaces them.
  sshPubKeys = pkgs.writeShellApplication {
    name = "ssh-pub-keys";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.openssh
    ];
    text = ''
      # Matches "<type> <base64> [comment]" and parses with ssh-keygen so a malformed literal never becomes a trusted file.
      write_key() {
        local dest=$1 pubkey=$2 dir tmp
        dir=$(dirname "$dest")
        mkdir -p "$dir" && chmod 700 "$dir" || return 1
        tmp=$(mktemp "$dest.XXXXXX") || return 1
        if printf '%s\n' "$pubkey" >"$tmp" \
          && ssh-keygen -l -f "$tmp" >/dev/null 2>&1 \
          && chmod 644 "$tmp" \
          && mv "$tmp" "$dest"; then
          echo "ssh-pub-keys: wrote $dest" >&2
        else
          rm -f "$tmp"
          return 1
        fi
      }

      failed=0
      ${lib.concatMapStrings (i: ''
        write_key "${expandHome i.key}.pub" ${lib.escapeShellArg i.pubkey} || {
          echo "ssh-pub-keys: could not write ${i.key}.pub" >&2
          failed=1
        }
      '') pubkeys}
      ${lib.getExe allowedSignersWriter}
      # Retired identities (personal/employer software keys, FIDO2 signing credentials): no host may keep offering or trusting a stale public half.
      rm -f "$HOME/.ssh/id_personal.pub" "$HOME/.ssh/id_work.pub" "$HOME/.config/ssh/id_work.pub" \
        "$HOME"/.config/ssh-sk/k*/signing.pub

      exit "$failed"
    '';
  };
  # Work hosts may keep gcloud's one conventional key file, managed by the Google CLI.
  sshNoPrivateKeys = pkgs.writeShellApplication {
    name = "ssh-no-private-keys";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
      pkgs.gnugrep
      pkgs.openssh
    ];
    text = ''
      ssh_dir="''${1:-$HOME/.ssh}"
      [ -d "$ssh_dir" ] || exit 0
      failures=0
      while IFS= read -r -d "" file; do
        [ -f "$file" ] || continue
        if [ "''${2:-}" = --allow-gcloud-key ] \
          && [ "$file" = "''${ssh_dir%/}/google_compute_engine" ] \
          && [ ! -L "$file" ]; then
          continue
        fi
        if head -c 11 "$file" | grep -q -- '-----BEGIN'; then
          echo "ssh-no-private-keys: private key in $file" >&2
          failures=$((failures + 1))
          continue
        fi
        if ssh-keygen -y -P "" -f "$file" >/dev/null 2>&1; then
          echo "ssh-no-private-keys: private key in $file" >&2
          failures=$((failures + 1))
        fi
      done < <(find "$ssh_dir" \( -type f -o -type l \) -print0)
      [ "$failures" -eq 0 ]
    '';
  };

in
{
  home.packages = [
    sshPubKeys
    allowedSignersWriter
    sshNoPrivateKeys
  ];

  home.activation.sshPubKeys = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run ${lib.getExe sshPubKeys} || true
  '';

  # Public material lives outside ~/.ssh (no key/config storage there).
  home.activation.sshLayout = lib.hm.dag.entryAfter [ "sshPubKeys" ] ''
    ${pkgs.coreutils}/bin/mkdir -p "$HOME/.config/ssh"
    if [ -f "$HOME/.ssh/known_hosts" ] && [ ! -e "$HOME/.config/ssh/known_hosts" ]; then
      ${pkgs.coreutils}/bin/cp "$HOME/.ssh/known_hosts" "$HOME/.config/ssh/known_hosts"
    fi
    ${pkgs.coreutils}/bin/rm -f \
      "$HOME/.ssh/allowed_signers" \
      "$HOME/.ssh/config.work" \
      "$HOME/.ssh/id_work.pub" \
      "$HOME/.ssh/id_personal.pub" \
      "$HOME/.ssh/known_hosts" \
      "$HOME/.ssh/known_hosts.old"
  '';

  home.activation.checkSshPrivateKeys = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run ${lib.getExe sshNoPrivateKeys} "$HOME/.ssh" ${lib.optionalString config.machine.workHost "--allow-gcloud-key"}
  '';

  programs.git.settings.gpg.ssh.allowedSignersFile = allowedSigners;
}
