# Owner-selecting GitHub credentials: one sops-held PAT per account for HTTPS git and gh (humans
# and Maki). Every consumer asks github-token-file which PAT a repository's owner gets, so they
# cannot disagree and work and personal repos never share a token.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  secretPath = import ../lib/secret-path.nix;

  # Exact owners, lowercased to match the case-folded owner below.
  workOwners = lib.concatMapStringsSep "|" lib.toLower config.user.work.githubOwners;

  # sops-nix puts the PATs in /run/secrets on NixOS; a home-only Darwin host
  # declares them in home-manager sops, which owns their path.
  patFile = secretPath config;

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

  # git credential helper: answers only GitHub over HTTPS, owner from the request path (useHttpPath)
  # so the token follows the URL, not the cwd. Without a token it sends quit=1 so git fails naming
  # the owner instead of prompting. The token never appears in argv or the environment.
  credentialHelper = pkgs.writeShellApplication {
    name = "github-credential-helper";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      operation="''${1:-get}"
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
      # `www` is the same service, never a lookalike label; a direct fill for it must fail closed like a rewritten remote.
      host=''${host#www.}
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

  # gh also uses GH_TOKEN for its git calls, so it must match the targeted repository. Small,
  # predictable rule, not a reimplementation of gh's flags: -R/--repo or GH_REPO, else the `api`
  # endpoint, else the checkout's default remote, else personal. Positional repo arguments are not
  # guessed (use -R); a miss only gets the other account's token refused. Other hosts get no token
  # (gh would send GH_TOKEN to *.ghe.com).
  ghWithPat = pkgs.writeShellApplication {
    name = "gh-pat";
    runtimeInputs = [
      pkgs.gh
      pkgs.coreutils
      pkgs.git
      pkgs.gnugrep
    ];
    text = ''
      # An explicit GH_TOKEN always wins (CI, a one-off work org command).
      if [ -n "''${GH_TOKEN:-}" ]; then
        exec ${pkgs.gh}/bin/gh "$@"
      fi
      # Another GitHub host (Enterprise, *.ghe.com) is not either account's, and
      # gh would send GH_TOKEN there too: leave gh to its own login.
      other_host() {
        if [ -n "''${GH_PAT_RESOLVE_ONLY:-}" ]; then
          printf '<other-host>\n'
          exit 0
        fi
        exec env -u GH_TOKEN ${pkgs.gh}/bin/gh "$@"
      }
      if [ -n "''${GH_HOST:-}" ] && [ "''${GH_HOST,,}" != github.com ]; then
        other_host "$@"
      fi
      prev=""
      for arg in "$@"; do
        case "$prev|''${arg,,}" in
          --hostname\|github.com | *\|--hostname=github.com) ;;
          --hostname\|* | *\|--hostname=*) other_host "$@" ;;
          *\|https://* | *\|http://*)
            case "''${arg,,}" in
              https://github.com/* | https://api.github.com/* | https://www.github.com/* | http://github.com/*) ;;
              *) [ "''${1:-}" = api ] && other_host "$@" ;;
            esac
            ;;
        esac
        prev=$arg
      done

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
        endpoint=''${endpoint%%\?*}
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

      # gh's default remote: an explicit `gh repo set-default` (either the
      # remote marked `base` or the owner/repo it records), else upstream,
      # github, origin, else a checkout's only remote.
      checkout_owner() {
        local resolved="" remote="" url remotes
        while read -r key value; do
          case "$value" in
            base) key=''${key#remote.} && remote=''${key%.gh-resolved} ;;
            */*) resolved=$value ;;
          esac
        done < <(git config --get-regexp '^remote\..*\.gh-resolved$' 2>/dev/null || true)
        if [ -n "$resolved" ]; then
          owner_of "$resolved"
          return 0
        fi
        remotes=$(git remote 2>/dev/null) || return 0
        [ "$(printf '%s\n' "$remotes" | grep -c .)" = 1 ] && [ -z "$remote" ] && remote=$remotes
        for candidate in "$remote" upstream github origin; do
          [ -n "$candidate" ] || continue
          if url=$(git remote get-url "$candidate" 2>/dev/null); then
            case "''${url,,}" in
              *github.com[:/]*) ;;
              *) printf '%s' "@other-host" && return 0 ;;
            esac
            url=''${url%/}
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
      if [ "$explicit" = 0 ] && [ "''${1:-}" = api ]; then
        owner=$(api_owner "''${@:2}")
        [ -n "$owner" ] && explicit=1
      fi
      if [ "$explicit" = 0 ]; then
        owner=$(checkout_owner)
        [ "$owner" = "@other-host" ] && other_host "$@"
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

  # The PAT-aware wrapper is `gh`; `gh-pat` stays for the sandbox shim. It execs the real gh by absolute path, so no recursion.
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
      # GitHub is HTTPS plus the owner's PAT for both accounts (no SSH identity for git), so every SSH
      # spelling is rewritten, including `www` and plain `http`: git picks the longest prefix, so all
      # land on the bare https host the helper answers and fail closed instead of prompting.
      url."https://github.com/".insteadOf = [
        # Longest match wins, so the slash-led scp form loses its extra slash.
        "git@github.com:/"
        "git@github.com:"
        "github.com:"
        "ssh://git@github.com/"
        "ssh://git@github.com:22/"
        "ssh://github.com/"
        "https://www.github.com/"
        "http://github.com/"
        "http://www.github.com/"
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
