origin_parts() {
  local url path host owner repo
  url=$(git remote get-url origin 2>/dev/null) || return 1
  case "$url" in
    git@*:*)
      host=${url#git@}
      host=${host%%:*}
      path=${url#*:}
      ;;
    ssh://git@*/*)
      host=${url#ssh://git@}
      host=${host%%/*}
      path=${url#ssh://git@*/}
      ;;
    https://*/*/*|http://*/*/*)
      path=${url#*://}
      host=${path%%/*}
      path=${path#*/}
      ;;
    *) return 1 ;;
  esac
  path=${path%.git}
  owner=${path%%/*}
  repo=${path#*/}
  repo=${repo%%/*}
  [ -n "$host" ] && [ -n "$owner" ] && [ -n "$repo" ] || return 1
  printf '%s\t%s\t%s\n' "$host" "$owner" "$repo"
}
