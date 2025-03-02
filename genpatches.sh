#!/usr/bin/env bash

set -eo pipefail

function usage() {
  echo "Usage: $0 <mastodon dir> <base ref> [prefix=owocafe/]"
  exit 1
}

mastodir=$1
baseref=$2
prefix=${3:-owocafe/}

DIR="$(realpath "$(dirname "${BASH_SOURCE[0]}")")"

test -n "$mastodir" || usage
test -n "$baseref" || usage

(
  cd "$mastodir" || exit
  git for-each-ref --format '%(refname)' refs/heads |
    grep -e "$prefix" | while read -r branch; do
    branch=${branch#refs/heads/}
    git format-patch "${baseref}..${branch}" --stdout >"$DIR/patches/${branch#"$prefix"}.patch"
  done
)
