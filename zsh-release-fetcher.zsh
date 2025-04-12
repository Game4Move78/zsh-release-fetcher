zrget_extract_fpr() {
  gpg --list-packets \
  | awk '/issuer fpr v4/ { gsub(/[()]/, "", $NF); print $NF; found=1 } END { if (!found) exit 1 }'
}

zrget_gh_release_key() {
  local repo="$1"
  local tag_name="$2"
  local url=$(gh api /repos/$repo/git/ref/tags/$tag_name -q '.object.url')
  gh api "$url" \
  | jq -rceM '
    .verification
    | if .verified != true or .reason != "valid" then
        halt_error(1)
      end
    | .signature
  ' \
  | zrget_extract_fpr
}

is_trusted() {
  local key_id="$1"
  gpg --with-colons --list-keys "$key_id" 2>/dev/null \
    | awk -F: '$1 == "pub" && $2 ~ /^[mu]$/ { exit 0 } END { exit 1 }'
}

zrget_gh_trust_key() {
  local key_id
  key_id=$(zrget_gh_release_key "$@") || return $?
  local tmpdir="$PWD/.zrget-keyring/"
  mkdir -p "$tmpdir"
  chmod 700 "$tmpdir"
  if ! gpg --homedir "$tmpdir" --batch --quiet --fingerprint "$key_id" 1>&2 2> /dev/null; then
    gpg --homedir "$tmpdir" --batch --yes --quiet --recv-keys "$key_id" || return $?
    gpg --homedir "$tmpdir" --batch --quiet --fingerprint "$key_id" 1>&2 || return $?
  fi
  # 3 = full trust, 4 = ultimate, 5 = never trust (still explicit trust assignment)
  gpg --homedir "$tmpdir" --export-ownertrust \
  | awk -F:  -v key_id="$key_id" '$1 == key_id && $2 ~ /^[345]$/ { found=1 } END { exit (found ? 0 : 1) }'
  if [[ $? -eq 0 ]]; then
    return 0
  fi
  printf "Do you trust this key? [y/N] " >&2
  local response
  read -r response < /dev/tty
  case "$response" in
    [yY][eE][sS]|[yY])
      echo "$key_id:3" | gpg --homedir "$tmpdir" --batch --quiet --import-ownertrust >/dev/null 2>&1
      return $?
      ;;
    *)
      return 1
      ;;
  esac
}

zrget_gh_check() {
  if ! command -v gh >/dev/null 2>&1; then
    echo "Error: 'gh' (GitHub CLI) is not installed or not in your PATH." >&2
    return 1
  fi
}

zrget_gh_get_assets() {
  zrget_gh_check || return $?
  local filter="$1"
  shift 1
  local repo="$1"
  shift 1
  local patterns="${(F)@}"
  local jq_query='
  .tagName as $tagName
  | .assets[]
  | .tagName = $tagName
  | select(
      .name
    | . as $name
    | all(
      ($patterns | split("\n")[]);
      . as $pat | $name | test($pat)
    )
  )
   '
  gh release view -R "$repo" --json assets,tagName \
    | jq -rceM \
         --arg patterns "$patterns" \
         "$jq_query | $filter"
}

zrget_gh_get_options() {
  zrget_gh_get_assets .name $@
}

zrget_gh_get_all() {
  local repo="$1"
  local is_first=0
  zrget_gh_get_assets '[.name, .url, .tagName] | @tsv' "$@" \
  | while IFS=$'\t' read -r name url tag_name; do
    if [[ "$is_first" -eq 0 ]]; then
      zrget_gh_trust_key "$repo" "$tag_name" || return $?
      is_first=1
    fi
    echo wget -O "$name" "$url" >&2
    wget -O "$name" "$url"
  done
}

zrget_gh_get_one() {
  local repo="$1"
  local name url tag_name

  zrget_gh_get_assets '[.name, .url, .tagName] | @tsv' "$@" \
  | fzf -0 -d $'\t' --with-nth=1 --select-1 \
  | IFS=$'\t' read -r name url tag_name

  zrget_gh_trust_key "$repo" "$tag_name" || return $?

  echo wget -O "$name" "$url" >&2
  wget -qO- "$url"
}

zrget_gh_get_tar() {
  local name
  zrget_gh_get_one "$@" \
  | tar xz
}

zrget_gh_get_file() {
  for arg in $@; do
    zrget_gh_get_all "$arg"
  done
}

zrget() {
  if [[ "$1" == "tar" ]]; then
    shift 1
    zrget_gh_get_tar "$@"
  elif [[ "$1" == "file" ]]; then
    shift 1
    zrget_gh_get_file "$@"
  fi
}

_zrget() {
  if [[ ${#words} -le 2 ]]; then
    local -a opts=("tar" "file")
    compadd -S' ' -- "${opts[@]}"
    return
  fi
  local -a opts
  local cur
  if [[ ${#words} -gt 3 ]]; then
    cur="${(Q)words[CURRENT]}"
  fi
  for opt in $(zrget_gh_get_options "${(Q)words[3]}" "${(Q)words[CURRENT]}" 2> /dev/null); do
    opts+=("${(@f)opt}")
  done
  local opt_S
  if [[ ${#opts} -eq  1 ]]; then
    opt_s=''
  else
    opt_s=' '
  fi
  echo "${opts[@]}"
  compadd -S "$opt_s" -- "${opts[@]}"
}

compdef _zrget zrget
