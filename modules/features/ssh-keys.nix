# The key files on disk that ssh (`IdentityFile`), git signing and signature
# verification read. Proton Pass holds every identity: its agent serves the
# private halves (proton-pass.nix), and `ssh-pub-keys` fetches the public halves
# from the vault. Activation and bootstrap both run `ssh-pub-keys`, so a fresh
# host and a long-lived one end up in the same state.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.user;
  expandHome = lib.replaceStrings [ "~" ] [ "$HOME" ];

  # title is the vault item; email is the principal its signatures verify as.
  identities = [
    {
      title = "Personal";
      key = cfg.sshKey;
      inherit (cfg) email;
    }
    {
      title = "Work";
      key = cfg.work.sshKey;
      inherit (cfg.work) email;
    }
  ];
  vault = "Identity";
  allowedSigners = "~/.ssh/allowed_signers";

  # Signatures only verify against keys listed here; rebuilt from whichever
  # .pub files exist, so a host without the work key still trusts the personal
  # one.
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
        '') identities}
      } >"$tmp"
      mv "$tmp" "$out"
    '';
  };

  # Fetches only missing files, then refreshes allowed_signers. Exits non-zero
  # while any key is still missing so bootstrap can tell; activation ignores
  # that, since it runs before bootstrap has logged pass-cli in.
  sshPubKeys = pkgs.writeShellApplication {
    name = "ssh-pub-keys";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.openssh
    ];
    text = ''
      # Appended, not in runtimeInputs: an earlier pass-cli on PATH (the test's
      # fake) wins, and activation's bare PATH still finds this one.
      PATH=$PATH:${config.services.proton-pass-agent.package}/bin
      # The agent's provider: any other makes pass-cli force a logout and
      # delete the session, and activation does not see session variables.
      export PROTON_PASS_KEY_PROVIDER=${config.home.sessionVariables.PROTON_PASS_KEY_PROVIDER}

      # Every failure returns instead of exiting, so one bad key never stops
      # the next or leaves a temp file behind.
      fetch() {
        local title=$1 dest=$2 dir key tmp
        [ -s "$dest" ] && return 0
        key=$(pass-cli item view --vault-name ${vault} --item-title "$title" --field public_key </dev/null) \
          || return 1
        # Exactly "<type> <base64> [comment]" (no authorized_keys options,
        # no CR) that ssh-keygen also parses: an error printed to stdout must
        # not land where ssh and git will trust it, and allowed_signers reads
        # the first two fields as type and key.
        [[ $key =~ ^(ssh|ecdsa|sk)-[^[:space:]]+\ [A-Za-z0-9+/]+=*(\ [^[:cntrl:]]*)?$ ]] || return 1
        dir=$(dirname "$dest")
        # Always: home-manager may have created ~/.ssh first with the umask.
        mkdir -p "$dir" && chmod 700 "$dir" || return 1
        tmp=$(mktemp "$dest.XXXXXX") || return 1
        if printf '%s\n' "$key" >"$tmp" \
          && ssh-keygen -l -f "$tmp" >/dev/null 2>&1 \
          && chmod 644 "$tmp" \
          && mv "$tmp" "$dest"; then
          echo "ssh-pub-keys: wrote $dest from Proton Pass" >&2
        else
          rm -f "$tmp"
          return 1
        fi
      }

      missing=0
      ${lib.concatMapStrings (i: ''
        fetch ${lib.escapeShellArg i.title} "${expandHome i.key}.pub" || {
          echo "ssh-pub-keys: no usable '${i.title}' key from the ${vault} vault (see any pass-cli error above)" >&2
          missing=1
        }
      '') identities}
      ${lib.getExe allowedSignersWriter}

      if ((missing)); then
        echo "ssh-pub-keys: if pass-cli is logged out, log in with" >&2
        echo "  PROTON_PASS_KEY_PROVIDER=$PROTON_PASS_KEY_PROVIDER pass-cli login --interactive" >&2
        echo "then run ssh-pub-keys; otherwise check the item exists in the ${vault} vault." >&2
        exit 1
      fi
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
