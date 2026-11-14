#!/bin/sh
set -eu

dir=${REX_WORKSPACES_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/rex/rex-workspaces}
from_source='see "Building from source" in the README: https://github.com/agarun/rex-workspaces#building-from-source'

fail() { printf 'rex-workspaces: %s\n' "$*" >&2; exit 1; }

command -v rex >/dev/null || fail "rex is required: https://www.superlogical.com/rex/docs/installation"
command -v curl >/dev/null || fail "curl is required"
command -v tar >/dev/null || fail "tar is required"

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) t=aarch64-apple-darwin ;;
  Darwin-x86_64) t=x86_64-apple-darwin ;;
  Linux-x86_64) t=x86_64-unknown-linux-musl ;;
  Linux-aarch64 | Linux-arm64) t=aarch64-unknown-linux-musl ;;
  *) fail "no release for this machine ($(uname -s) $(uname -m)); $from_source" ;;
esac

if [ -L "$dir" ] || [ -d "$dir/.git" ]; then
  fail "$dir is a link or git checkout from another install; not overwriting it"
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
url="https://github.com/agarun/rex-workspaces/releases/latest/download/rex-workspaces-$t.tar.gz"

curl -fsSL "$url" -o "$tmp/archive.tar.gz" || fail "download failed: $url; $from_source"
tar -xzf "$tmp/archive.tar.gz" -C "$tmp" || fail "could not unpack the download; $from_source"
[ -x "$tmp/rex-workspaces/bin/rex-workspaces" ] || fail "unexpected archive contents; $from_source"

rm -rf "$dir"
mkdir -p "$(dirname "$dir")"
mv "$tmp/rex-workspaces" "$dir"

echo "Downloaded rex-workspaces ($t) to $dir"
"$dir/bin/rex-workspaces" install
