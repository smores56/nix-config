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

  # `gh` reads GH_TOKEN, so infer the owner from origin and exec the real gh.
  # Named separately on purpose: overriding `gh` globally would change the
  # normal SSH-agent flow; the sandbox aliases this to `gh`.
  ghWithPat = pkgs.writeShellApplication {
    name = "gh-pat";
    runtimeInputs = [ pkgs.gh ];
    text = ''
      owner=""
      if url=$(git remote get-url origin 2>/dev/null); then
        owner=$(printf '%s' "$url" | sed -E 's#^.*[:/]([^/]+)/[^/]+(\.git)?$#\1#')
      fi

      token_file=/run/secrets/github-personal-pat
      case "''${owner,,}" in
        ${workGlob}) token_file=/run/secrets/github-work-pat ;;
      esac
      if [ ! -r "$token_file" ]; then
        echo "gh-pat: no token for owner ' ''${owner:-<none>}' (or the sops file is missing)" >&2
        exit 1
      fi

      export GH_TOKEN
      GH_TOKEN=$(tr -d '[:space:]' <"$token_file")
      exec gh "$@"
    '';
  };
in
{
  # /run/secrets only exists on NixOS hosts; the macOS work host keeps its own
  # credential story.
  config = lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
    home.packages = [
      credentialHelper
      ghWithPat
    ];
  };
}
