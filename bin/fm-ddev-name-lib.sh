#!/usr/bin/env bash

fm_ddev_normalize() {
  printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9-]/-/g; s/-\{2,\}/-/g; s/^-*//; s/-*$//'
}

fm_ddev_task_suffix() {
  local raw=$1 safe digest
  safe=$(fm_ddev_normalize "$raw") || return 1
  [ -n "$safe" ] || return 1
  if [ "$safe" != "$raw" ] || [ "${#safe}" -gt 61 ]; then
    digest=$(python3 -c 'import hashlib, sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest()[:6])' "$raw") || return 1
    safe="${safe:0:54}-$digest"
  fi
  printf '%s\n' "$safe"
}

fm_ddev_task_name_matches() {
  local name=$1 id=$2 suffix
  suffix=$(fm_ddev_task_suffix "$id") || return 1
  [ "${name%-"$suffix"}" = "$name" ] || return 0
  suffix=$(fm_ddev_normalize "$id") || return 1
  [ -n "$suffix" ] && [ "${name%-"$suffix"}" != "$name" ]
}
