# Owner-selecting GitHub credentials for tooling that cannot use the SSH agent
# (Maki inside its sandbox, HTTPS remotes). The PATs live in sops as
# user-readable files; the helper picks one by the repository owner git passes
# in the credential request, so work repos and personal repos never share a
# token.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  workGlob = config.user.work.githubOwnerGlob;

  # sops-nix puts the PATs in /run/secrets on NixOS; a home-only Darwin host
  # declares them in home-manager sops, which owns their path.
  patFile = name: config.sops.secrets.${name}.path or "/run/secrets/${name}";
  # Shell that sets token_file from $owner, shared so git and gh can never
  # disagree about which token an owner gets.
  selectTokenFile = ''
    token_file=${lib.escapeShellArg (patFile "github-personal-pat")}
    case "''${owner,,}" in
      ${workGlob}) token_file=${lib.escapeShellArg (patFile "github-work-pat")} ;;
    esac
  '';

  # git credential protocol: `git credential <helper> get` with key=value lines
  # on stdin (notably `host` and `path=owner/repo.git`) and key=value on stdout.
  # The token is read from a user-readable sops file and never appears in argv
  # or the environment.
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

      ${selectTokenFile}
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
      ${selectTokenFile}
      if [ -r "$token_file" ]; then
        token=$(tr -d '[:space:]' <"$token_file")
      fi

      if [ -z "$token" ]; then
        printf "gh: no token for owner '%s'\n" "''${owner:-<none>}" >&2
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
      credentialHelper
    ];
    programs.gh.package = ghAlias;
  };
}
