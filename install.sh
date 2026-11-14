#!/bin/sh
set -eu

repo=agarun/rex-workspaces
dir=${REX_WORKSPACES_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/rex/rex-workspaces}

say() { printf '%s\n' "$*"; }
fail() { printf 'rex-workspaces: %s\n' "$*" >&2; exit 1; }

command -v rex >/dev/null || fail "rex is required: https://www.superlogical.com/rex/docs/installation"

target() {
  case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) echo aarch64-apple-darwin ;;
    Darwin-x86_64) echo x86_64-apple-darwin ;;
    Linux-x86_64) echo x86_64-unknown-linux-musl ;;
    Linux-aarch64 | Linux-arm64) echo aarch64-unknown-linux-musl ;;
  esac
}

fetch_release() {
  t=$(target)
  [ -n "$t" ] && command -v curl >/dev/null || return 1
  tmp=$(mktemp -d)
  url="https://github.com/$repo/releases/latest/download/rex-workspaces-$t.tar.gz"
  if ! curl -fsSL "$url" | tar -xz -C "$tmp" 2>/dev/null; then
    rm -rf "$tmp"
    return 1
  fi
  rm -rf "$dir"
  mkdir -p "$(dirname "$dir")"
  mv "$tmp/rex-workspaces" "$dir"
  rm -rf "$tmp"
  say "Downloaded rex-workspaces ($t) to $dir"
}

build_from_source() {
  command -v git >/dev/null || fail "git is required to build from source"
  command -v cargo >/dev/null || fail "no prebuilt binary for this machine; install Rust (https://rustup.rs) and run again"
  if [ -d "$dir/.git" ]; then
    git -C "$dir" pull --ff-only --quiet
  else
    mkdir -p "$(dirname "$dir")"
    git clone --quiet --depth 1 "https://github.com/$repo" "$dir"
  fi
  say "Building rex-workspaces..."
  cargo build --release --quiet --manifest-path "$dir/Cargo.toml"
  mkdir -p "$dir/bin"
  rm -f "$dir/bin/rex-workspaces"
  cp "$dir/target/release/rex-workspaces" "$dir/bin/rex-workspaces"
}

if [ -d "$dir/.git" ] || ! fetch_release; then
  build_from_source
fi

"$dir/bin/rex-workspaces" install
