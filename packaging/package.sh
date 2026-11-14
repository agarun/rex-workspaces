#!/bin/sh
set -eu

target=$1
binary=$2
out=$3
here=$(cd -- "$(dirname -- "$0")/.." && pwd)
stage=$(mktemp -d)
pkg=$stage/rex-workspaces

mkdir -p "$pkg/bin" "$pkg/examples" "$out"
cp "$binary" "$pkg/bin/rex-workspaces"
cp -R "$here/init.lua" "$here/lib" "$here/schema.json" "$here/README.md" "$pkg/"
cp -R "$here/examples/workspaces.json" "$here/examples/my-project" "$pkg/examples/"
rm -f "$pkg/examples/my-project/.last-start" "$pkg/examples/my-project/.last-stop" "$pkg/examples/my-project/.history"
tar -czf "$out/rex-workspaces-$target.tar.gz" -C "$stage" rex-workspaces
rm -rf "$stage"
echo "$out/rex-workspaces-$target.tar.gz"
