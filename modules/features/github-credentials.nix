# Owner-selecting GitHub credentials for tooling that cannot use the SSH agent
# (Maki inside its sandbox). The PATs live in sops as user-readable files; the
# helper picks one by the repository owner git passes in the credential
# request, so work repos and personal repos never share a token.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  workGlob = config.user.work.githubOwnerGlob;

  # git credential protocol: `git credential <helper> get` with key=value lines
  # on stdin (notably `host` and `path=owner/repo.git`) and key=value on stdout.
  # The token is read from a root-installed, user-readable sops file and never
  # appears in argv or the environment.
  credentialHelper = pkgs.writeShellApplication {
    name = "github-credential-helper";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.gnused
    ];
    text = ''
      operation="''${1:-get}"
      # Nothing to store or erase: sops owns the token files.
      [ "$operation" = get ] || exit 0

      host="" path=""
      while IFS='=' read -r key value; do
        [ -z "$key" ] && break
        case "$key" in
          host) host=$value ;;
          path) path=$value ;;
        esac
      done

      [ "$host" = github.com ] || exit 0
      owner="''${path#/}"
      owner="''${owner%%/*}"
      owner="''${owner%.git}"

      token_file=/run/secrets/github-personal-pat
      case "''${owner,,}" in
        ${workGlob}) token_file=/run/secrets/github-work-pat ;;
      esac
      [ -r "$token_file" ] || exit 0

      printf 'username=x-access-token\npassword=%s\n' "$(tr -d '[:space:]' <"$token_file")"
    '';
  };

  # `gh` reads GH_TOKEN. The PAT is selected from the repository owner so the
  # work and personal tokens never mix. This is installed as the real `gh` so
  # humans and agents do not need an env-var ritual or AGENTS.md instructions.
  ghWithPat = pkgs.writeShellApplication {
    name = "gh-pat";
    runtimeInputs = [
      pkgs.gh
      pkgs.coreutils
      pkgs.git
      pkgs.gnused
    ];
    text = ''
      # An explicit GH_TOKEN always wins (CI, a one-off work org command).
      if [ -n "''${GH_TOKEN:-}" ]; then
        exec ${pkgs.gh}/bin/gh "$@"
      fi

      owner=""
      if url=$(git remote get-url origin 2>/dev/null); then
        owner=$(printf '%s' "$url" | sed -E 's#^.*[:/]([^/]+)/[^/]+(\.git)?$#\1#')
      fi

      token=""
      if [ "$(uname -s)" = Darwin ]; then
        # macOS has no /run/secrets: the same PAT is a Keychain item. Prefer
        # the owner-specific item, then the agent's generic work item.
        item=maki-github-personal-pat
        case "''${owner,,}" in
          ${workGlob}) item=maki-github-work-pat ;;
        esac
        token=$(/usr/bin/security find-generic-password -s "$item" -w 2>/dev/null) || token=
        if [ -z "$token" ]; then
          token=$(/usr/bin/security find-generic-password -s maki-github-pat -w 2>/dev/null) || token=
        fi
      else
        token_file=/run/secrets/github-personal-pat
        case "''${owner,,}" in
          ${workGlob}) token_file=/run/secrets/github-work-pat ;;
        esac
        if [ -r "$token_file" ]; then
          token=$(tr -d '[:space:]' <"$token_file")
        fi
      fi

      if [ -z "$token" ]; then
        echo "gh: no token for owner ' ''${owner:-<none>}'" >&2
        exit 1
      fi

      export GH_TOKEN="$token"
      exec ${pkgs.gh}/bin/gh "$@"
    '';
  };

  # Install the PAT-aware wrapper as `gh`, while keeping `gh-pat` for the
  # sandbox shim. The wrapper execs the real gh by absolute path, so the
  # symlink cannot recurse.
  ghAlias = pkgs.runCommand "gh" { meta.mainProgram = "gh"; } ''
    mkdir -p $out/bin
    ln -s ${ghWithPat}/bin/gh-pat $out/bin/gh
  '';

in
{
  config = {
    home.packages = [
      ghWithPat
    ]
    ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [ credentialHelper ];
    programs.gh.package = ghAlias;
  };
}
