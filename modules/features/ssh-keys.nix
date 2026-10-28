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
  yubikeyIdentities = [
    {
      key = "~/.config/ssh-sk/piv-k1";
      pubkey = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBJ34zXLDQMZYvFX1q1fEMJ1/uGWvAtQUmu7/lzGqdWJBSAo2RPiYeeCZnA7AIhfwSwCIIv1sJWgopllQifFmZEc= smores piv k1";
    }
    {
      key = "~/.config/ssh-sk/piv-k2";
      pubkey = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBMcpVmF/c9KcRgBlgRVp/gjrtjuB/+0U1nURKnep+dAt1NtUztpWtwlz7o3drWTHzydNaGZ39uO21TQ3rxMEOBA= smores piv k2";
    }
    {
      key = "~/.config/ssh-sk/piv-k3";
      pubkey = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBOJHHVoKZWLnC1EVMVxFv9eNOtkZ+tJFI5TctBvOuzGAfYV0rlm6xv37RF2Pf+8DjUVEnwh9aGYwUsEFOoHUrPM= smores piv k3";
    }
    {
      key = "~/.config/ssh-sk/k1/signing";
      pubkey = "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIONu9lg+sGskfOnluRJc+K4QpIKmrPG9AZdkQGUnOwAPAAAAC3NzaDpzaWduLWsx smores sign k1";
    }
    {
      key = "~/.config/ssh-sk/k2/signing";
      pubkey = "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIL3jMFzM8BHpOKzCdd9rFMDYcKGgYELD3/Be3HDSN/UUAAAAC3NzaDpzaWduLWsy smores sign k2";
    }
    {
      key = "~/.config/ssh-sk/k3/signing";
      pubkey = "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIJb8e2eGxTw6x8gDgrT0ZhyBr1tT48mZRKtQcCSDwqlCAAAAC3NzaDpzaWduLWsz smores sign k3";
    }
  ];

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
in
{
  home.packages = [
    sshPubKeys
    allowedSignersWriter
  ];

  home.activation.sshPubKeys = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run ${lib.getExe sshPubKeys} || true
  '';

  programs.git.settings.gpg.ssh.allowedSignersFile = allowedSigners;
}
