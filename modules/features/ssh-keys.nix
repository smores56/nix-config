# The key files on disk that ssh (`IdentityFile`), git signing and signature
# verification read. The public halves are committed here (public by definition),
# so a fresh machine needs no vault round trip to get them; the private halves
# stay in Proton Pass (until the FIDO2 enrollment in T1), served by its agent.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.user;
  expandHome = lib.replaceStrings [ "~" ] [ "$HOME" ];

  # Software identities are retained for the legacy GitHub-auth path until
  # T0c removes the Pass agent; the YubiKey keys below are the only git
  # signing identities going forward.
  softwareIdentities = [
    {
      key = cfg.sshKey;
      inherit (cfg) email;
      pubkey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEu3DfhswY9f9hum/0OhAw2833CkZOP6wVKW5yJk6GpU sam@sammohr.dev";
    }
    {
      key = cfg.work.sshKey;
      inherit (cfg.work) email;
      pubkey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJ8f4okBI4niVjsR+lkgvfhRtVt1c/hRZ8POoBaQySog smohr@blitzy.com";
    }
  ];

  # One entry per YubiKey and credential. The public halves are committed, so
  # a fresh host writes the files ssh/git need without the key inserted.
  yubikeyKeys = import ../lib/yubikey-keys.nix;
  yubikeyIdentities = map (k: {
    key = "~/.config/ssh-sk/${k.key}";
    inherit (k) pubkey;
  }) (yubikeyKeys.piv ++ yubikeyKeys.signing);

  pubkeys = softwareIdentities ++ yubikeyIdentities;
  allowedSigners = "~/.ssh/allowed_signers";

  # Signatures only verify against keys listed here; rebuilt from whichever
  # keys exist, so a host without the work key still trusts the personal one.
  allowedSignersWriter = pkgs.writeShellApplication {
    name = "ssh-allowed-signers";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      out=${expandHome allowedSigners}
      # No ~/.ssh yet (fresh host) means no keys to verify against.
      [ -d "$(dirname "$out")" ] || exit 0
      tmp=$(mktemp "$out.XXXXXX")
      entry() {
        # principal, git-only namespace, then key type and body (no comment)
        if [ -s "$2" ]; then
          # read fails at EOF without a trailing newline but still fills
          # the fields, which hand-pasted .pub files often lack
          read -r type body _ <"$2" || [ -n "''${type:-}" ]
          printf '%s namespaces="git" %s %s\n' "$1" "$type" "$body"
        fi
      }
      {
        ${lib.concatMapStrings (i: ''
          entry ${lib.escapeShellArg i.email} "${expandHome i.key}.pub"
        '') softwareIdentities}
        ${lib.concatMapStrings (i: ''
          entry ${lib.escapeShellArg cfg.email} "${expandHome i.key}.pub"
          entry ${lib.escapeShellArg cfg.work.email} "${expandHome i.key}.pub"
        '') yubikeyIdentities}
        ${lib.optionalString (builtins.elem "server" config.machine.profiles) ''
          maki_key="$HOME/.config/maki/signing_ed25519.pub"
          if [ -s "$maki_key" ]; then
            entry ${lib.escapeShellArg cfg.email} "$maki_key"
            entry ${lib.escapeShellArg cfg.work.email} "$maki_key"
          fi
        ''}
      } >"$tmp"
      mv "$tmp" "$out"
    '';
  };

  # Writes the committed public halves and refreshes allowed_signers. This is
  # declarative: a changed key in Nix replaces the file at the next activation.
  # Activation ignores failures (it may run before ~/.ssh is writable); bootstrap
  # surfaces them.
  sshPubKeys = pkgs.writeShellApplication {
    name = "ssh-pub-keys";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.openssh
    ];
    text = ''
      # Matches "<type> <base64> [comment]" and parses with ssh-keygen, so a
      # malformed literal never becomes a file ssh and git will trust.
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

      exit "$failed"
    '';
  };
  # Identities normally come from the agent/security key. Work hosts may keep
  # gcloud's one conventional key file, which is managed by the Google CLI.
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

  home.activation.checkSshPrivateKeys = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run ${lib.getExe sshNoPrivateKeys} "$HOME/.ssh" ${lib.optionalString config.machine.workHost "--allow-gcloud-key"}
  '';

  programs.git.settings.gpg.ssh.allowedSignersFile = allowedSigners;
}
