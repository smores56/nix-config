# Owner-selecting GitHub credentials: each account's PAT is the one credential
# for HTTPS git and gh, for humans and for Maki. The PATs live in sops as
# user-readable files. Every consumer asks github-token-file which PAT the
# target repository's owner gets, so git, gh and the sandbox can never disagree
# and work and personal repos never share a token.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  # Exact owners, lowercased to match the case-folded owner below.
  workOwners = lib.concatMapStringsSep "|" lib.toLower config.user.work.githubOwners;

  # sops-nix puts the PATs in /run/secrets on NixOS; a home-only Darwin host
  # declares them in home-manager sops, which owns their path.
  patFile = name: config.sops.secrets.${name}.path or "/run/secrets/${name}";

  # owner -> PAT file path. Refuses anything that is not a GitHub account name,
  # so a crafted remote can never steer a token by its spelling.
  tokenFile = pkgs.writeShellApplication {
    name = "github-token-file";
    text = ''
      owner=''${1:-}
      [[ $owner =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]] || exit 1
      case "''${owner,,}" in
        ${workOwners}) printf '%s\n' ${lib.escapeShellArg (patFile "github-work-pat")} ;;
        *) printf '%s\n' ${lib.escapeShellArg (patFile "github-personal-pat")} ;;
      esac
    '';
  };

  # git credential protocol: `git credential <helper> get` with key=value lines
  # on stdin and key=value on stdout. Only GitHub over HTTPS is answered; the
  # owner comes from the request path (useHttpPath), so the token follows the
  # URL rather than the directory git runs in. Without a usable token it sends
  # quit=1, so git fails naming the owner instead of prompting for a password.
  # The token is read from the sops file and never appears in argv or the
  # environment.
  credentialHelper = pkgs.writeShellApplication {
    name = "github-credential-helper";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      operation="''${1:-get}"
      # Nothing to store or erase: sops owns the token files.
      [ "$operation" = get ] || exit 0

      protocol="" host="" path=""
      while IFS='=' read -r key value; do
        [ -z "$key" ] && break
        case "$key" in
          protocol) protocol=$value ;;
          host) host=$value ;;
          path) path=$value ;;
        esac
      done

      host=''${host,,}
      host=''${host%:443}
      [ "$protocol" = https ] && [ "$host" = github.com ] || exit 0

      stop() {
        printf 'github-credential-helper: %s\n' "$1" >&2
        printf 'quit=1\n'
        exit 0
      }

      # Dot segments would let curl resolve a path under one owner to another.
      case "/$path/" in
        */../* | */./* | *//*) stop "refusing path '$path'" ;;
      esac
      owner="''${path%%/*}"
      owner="''${owner%.git}"
      file=$(${lib.getExe tokenFile} "$owner") || stop "no GitHub owner in path '$path'"
      [ -r "$file" ] || stop "no token for owner '$owner'"
      printf 'username=x-access-token\npassword=%s\n' "$(tr -d '[:space:]' <"$file")"
    '';
  };

  # `gh` reads GH_TOKEN, and gh's own git calls (repo clone, pr checkout) use
  # it too, so the token must match the repository the command targets. The
  # owner comes from what gh itself would target, in gh's order: -R/--repo,
  # GH_REPO, the command's own argument (`repo <verb> owner/name`,
  # `pr|issue <verb> <URL>`, the `api` endpoint), then the checkout's default
  # remote; with nothing to go on, the personal account. Free-text values
  # (--body, -f query=...) never count. GH_PAT_RESOLVE_ONLY=1 prints the
  # resolved owner and exits, for tests.
  ghWithPat = pkgs.writeShellApplication {
    name = "gh-pat";
    runtimeInputs = [
      pkgs.gh
      pkgs.coreutils
      pkgs.git
    ];
    text = ''
      # An explicit GH_TOKEN always wins (CI, a one-off work org command).
      if [ -n "''${GH_TOKEN:-}" ]; then
        exec ${pkgs.gh}/bin/gh "$@"
      fi
      # Another GitHub host is not either account's; leave gh to its own login.
      if [ -n "''${GH_HOST:-}" ] && [ "''${GH_HOST,,}" != github.com ]; then
        exec ${pkgs.gh}/bin/gh "$@"
      fi

      # "owner/name", "github.com/owner/name" or a github.com URL -> owner;
      # prints nothing for anything else.
      owner_of() {
        local ref=$1
        case "''${ref,,}" in
          https://github.com/* | http://github.com/* | https://www.github.com/* | github.com/*)
            ref=''${ref#*://}
            ref=''${ref#*/}
            ;;
          https://api.github.com/*)
            ref=''${ref#*://*/}
            ;;
          *://*) return 0 ;;
        esac
        printf '%s' "''${ref%%/*}"
      }

      # The endpoint of `gh api`: its first operand, skipping flags and the
      # values of the flags that take one.
      api_owner() {
        local endpoint="" skip=0
        for arg in "$@"; do
          if [ "$skip" = 1 ]; then
            skip=0
            continue
          fi
          case "$arg" in
            -X | --method | -H | --header | -f | --raw-field | -F | --field | \
              -q | --jq | -t | --template | --input | --hostname | --cache | -p | --preview)
              skip=1
              ;;
            -*) ;;
            *)
              endpoint=$arg
              break
              ;;
          esac
        done
        case "''${endpoint,,}" in
          https://api.github.com/*) endpoint=''${endpoint#*://*/} ;;
          *://*) return 0 ;;
        esac
        endpoint=''${endpoint#/}
        case "$endpoint" in
          repos/*/* | orgs/*)
            endpoint=''${endpoint#*/}
            endpoint=''${endpoint%%/*}
            # {owner} / :owner placeholders are gh's own: fall back to the
            # checkout it would expand them from.
            case "$endpoint" in
              \{* | :*) ;;
              *) printf '%s' "$endpoint" ;;
            esac
            ;;
        esac
      }

      # gh's default remote: an explicit `gh repo set-default`, else upstream,
      # github, origin.
      checkout_owner() {
        local remote url
        remote=$(git config --get-regexp '^remote\..*\.gh-resolved$' 2>/dev/null |
          while read -r key value; do
            [ "$value" = base ] && { key=''${key#remote.}; printf '%s' "''${key%.gh-resolved}"; break; }
          done) || true
        for candidate in "$remote" upstream github origin; do
          [ -n "$candidate" ] || continue
          if url=$(git remote get-url "$candidate" 2>/dev/null); then
            url=''${url%.git}
            url=''${url%/*}
            printf '%s' "''${url##*[:/]}"
            return 0
          fi
        done
      }

      owner="" explicit=0 args=("$@")
      for ((i = 0; i < ''${#args[@]}; i++)); do
        case "''${args[i]}" in
          --) break ;;
          -R | --repo) owner=$(owner_of "''${args[i + 1]:-}") explicit=1 && break ;;
          --repo=*) owner=$(owner_of "''${args[i]#--repo=}") explicit=1 && break ;;
          -R?*) owner=$(owner_of "''${args[i]#-R}") explicit=1 && break ;;
        esac
      done
      if [ "$explicit" = 0 ] && [ -n "''${GH_REPO:-}" ]; then
        owner=$(owner_of "$GH_REPO") explicit=1
      fi
      if [ "$explicit" = 0 ]; then
        target=''${3:-}
        case "''${1:-}" in
          repo)
            case "$target" in
              -* | "") ;;
              */*) owner=$(owner_of "$target") explicit=1 ;;
            esac
            ;;
          pr | issue)
            case "''${target,,}" in
              https://* | http://* | github.com/*) owner=$(owner_of "$target") explicit=1 ;;
            esac
            ;;
          api)
            owner=$(api_owner "''${@:2}")
            [ -n "$owner" ] && explicit=1
            ;;
        esac
      fi
      if [ "$explicit" = 0 ]; then
        owner=$(checkout_owner)
        [ -n "$owner" ] || owner=${lib.escapeShellArg config.user.githubUser}
      fi

      if ! file=$(${lib.getExe tokenFile} "$owner"); then
        owner=""
        file=""
      fi
      if [ -n "''${GH_PAT_RESOLVE_ONLY:-}" ]; then
        printf '%s\n' "''${owner:-<none>}"
        exit 0
      fi

      token=""
      if [ -n "$file" ] && [ -r "$file" ]; then
        token=$(tr -d '[:space:]' <"$file")
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
      tokenFile
      ghWithPat
      credentialHelper
    ];
    programs.gh = {
      package = ghAlias;
      # gh's own helper answers with whatever GH_TOKEN the wrapper chose for the
      # directory git runs in; git asks the URL-based helper below instead.
      gitCredentialHelper.enable = false;
    };
    programs.git.settings = {
      # GitHub is HTTPS plus the owner's PAT for both accounts (no SSH identity
      # is registered for git), so every SSH spelling of a GitHub remote is
      # rewritten, matching the remote forms the owner includes recognise.
      url."https://github.com/".insteadOf = [
        # Longest match wins, so the slash-led scp form loses its extra slash.
        "git@github.com:/"
        "git@github.com:"
        "github.com:"
        "ssh://git@github.com/"
        "ssh://git@github.com:22/"
        "ssh://github.com/"
      ];
      # The empty entry drops inherited helpers (osxkeychain) for GitHub, so
      # only the owner-selecting helper ever answers.
      credential."https://github.com" = {
        helper = [
          ""
          (lib.getExe credentialHelper)
        ];
        useHttpPath = true;
      };
    };
  };
}
