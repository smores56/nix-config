unset CDPATH
CODE_ROOT=@CODE_ROOT@
# REPOS_CODE_ROOT redirects both listing and `get`, for tests.
ROOT=${REPOS_CODE_ROOT:-$CODE_ROOT}
WORK_FLAT=@WORK_FLAT@
# REPOS_WORK_FLAT overrides the flat folder, including disabling it in tests.
WORK_FLAT=${REPOS_WORK_FLAT-$WORK_FLAT}
WORK_OWNERS=(@WORK_OWNERS@)

# The flat work folder is a separate root. Skip owner links to it rather
# than scanning every checkout through each link.
list_repos() {
  local list_owner path flat_root=$WORK_FLAT flat_real="" owner_real real origin_owner owner_name
  local -A chosen=() matched=()
  shopt -s nullglob dotglob
  if [ -n "$flat_root" ] && [ -d "$flat_root" ]; then
    flat_real=$(cd -- "$flat_root" && pwd -P)
  fi
  {
    for list_owner in "$ROOT"/*/*; do
      [ -d "$list_owner" ] || continue
      if [ -L "$list_owner" ]; then
        owner_real=$(cd -- "$list_owner" && pwd -P)
        [ -z "$flat_real" ] || [ "$owner_real" != "$flat_real" ] || continue
      fi
      for path in "$list_owner"/*; do
        [ -d "$path" ] || continue
        if [ -d "$path/.git" ] || [ -f "$path/.git" ]; then
          real=$(cd -- "$path" && pwd -P)
          owner_name=${list_owner##*/}
          origin_owner=$owner_name
          if [ "$real" != "$path" ]; then
            origin_owner=$( (cd -- "$path" && origin_parts) | cut -f2 || true)
          fi
          if [ "${origin_owner,,}" = "${owner_name,,}" ]; then
            [ -n "${matched[$real]-}" ] || { matched[$real]=1; chosen[$real]=$path; }
          elif [ -z "${chosen[$real]-}" ]; then
            chosen[$real]=$path
          fi
        fi
      done
    done
    for real in "${!chosen[@]}"; do
      printf '%s\n' "${chosen[$real]}"
    done
    if [ -n "$flat_real" ]; then
      for path in "$flat_root"/*; do
        [ -d "$path" ] || continue
        if [ -d "$path/.git" ] || [ -f "$path/.git" ]; then
          printf '%s\n' "$path"
        fi
      done
    fi
  } | sort -u
}

# GitHub names are case-insensitive even when the local filesystem isn't.
# Refuse both flat-name collisions and checkouts still in old org dirs.
check_work_destination() {
  local host_dir owner_dir candidate flat_real="" owner_real name
  shopt -s nullglob dotglob
  for candidate in "$WORK_FLAT"/*; do
    name=${candidate##*/}
    if [ "$name" != "$repo" ] && [ "${name,,}" = "${repo,,}" ]; then
      printf 'repos get: %s conflicts with %s (GitHub names are case-insensitive)\n' "$dest" "$candidate" >&2
      return 1
    fi
  done
  [ ! -d "$WORK_FLAT" ] || flat_real=$(cd -- "$WORK_FLAT" && pwd -P)
  for host_dir in "$ROOT"/*; do
    name=${host_dir##*/}
    [ -d "$host_dir" ] && [ "${name,,}" = github.com ] || continue
    for owner_dir in "$host_dir"/*; do
      name=${owner_dir##*/}
      [ -d "$owner_dir" ] && [ "${name,,}" = "${owner,,}" ] || continue
      owner_real=$(cd -- "$owner_dir" && pwd -P)
      [ -z "$flat_real" ] || [ "$owner_real" != "$flat_real" ] || continue
      for candidate in "$owner_dir"/*; do
        name=${candidate##*/}
        if [ "${name,,}" = "${repo,,}" ]; then
          printf 'repos get: existing checkout or path at %s; inspect it before using %s\n' "$candidate" "$dest" >&2
          return 1
        fi
      done
    done
  done
}

normalize_repo() {
  local input=$1 host owner repo path
  case "$input" in
    git@*:*)
      host=${input#git@}
      host=${host%%:*}
      path=${input#*:}
      ;;
    ssh://git@*/*)
      host=${input#ssh://git@}
      host=${host%%/*}
      path=${input#ssh://git@*/}
      ;;
    https://*/*/*|http://*/*/*)
      path=${input#*://}
      host=${path%%/*}
      path=${path#*/}
      ;;
    */*/*)
      host=${input%%/*}
      path=${input#*/}
      ;;
    */*)
      host=github.com
      path=$input
      ;;
    *)
      printf 'repos get: expected owner/repo, host/owner/repo, or git URL: %s\n' "$input" >&2
      exit 2
      ;;
  esac
  path=${path%.git}
  owner=${path%%/*}
  repo=${path#*/}
  repo=${repo%%/*}
  [ -n "$host" ] && [ -n "$owner" ] && [ -n "$repo" ] || {
    printf 'repos get: could not parse repo: %s\n' "$input" >&2
    exit 2
  }
  printf '%s\t%s\t%s\n' "$host" "$owner" "$repo"
}

case "${1-}" in
  ""|list|ls) list_repos ;;
  get)
    [ $# -eq 2 ] || { printf 'usage: repos get <repo-or-url>\n' >&2; exit 2; }
    parts=$(normalize_repo "$2")
    IFS=$'\t' read -r host owner repo <<< "$parts"
    dest="$ROOT/$host/$owner/$repo"
    if [ -n "$WORK_FLAT" ]; then
      shopt -s nocasematch
      if [[ $host == github.com ]]; then
        for work_owner in "${WORK_OWNERS[@]}"; do
          if [[ $owner == "$work_owner" ]]; then
            dest="$WORK_FLAT/$repo"
            check_work_destination
            break
          fi
        done
      fi
      shopt -u nocasematch
    fi
    url="git@$host:$owner/$repo.git"
    if [ -e "$dest" ] || [ -L "$dest" ]; then
      existing=$( (cd -- "$dest" && origin_parts 2>/dev/null) | cut -f2,3 | tr '\t' / || true)
      if [ -n "$existing" ] && [ "${existing,,}" != "${owner,,}/${repo,,}" ]; then
        printf 'repos get: %s is already a checkout of %s (work repos share one flat folder)\n' "$dest" "$existing" >&2
      else
        printf 'repos get: destination exists: %s\n' "$dest" >&2
      fi
      exit 1
    fi
    mkdir -p "$(dirname "$dest")"
    git clone "$url" "$dest"
    printf '%s\n' "$dest"
    ;;
  *)
    printf 'usage: repos [list|get <repo-or-url>]\n' >&2
    exit 2
    ;;
esac
