#!/bin/sh
set -eu

version=${1#v}
dir=$2
repo=${REPO:-agarun/rex-workspaces}

sum() {
  file="$dir/rex-workspaces-$1.tar.gz"
  [ -f "$file" ] || { echo "formula.sh: missing $file" >&2; exit 1; }
  shasum -a 256 "$file" | cut -d' ' -f1
}

cat <<RUBY
class RexWorkspaces < Formula
  desc "Start, stop and restart project workspaces in Rex"
  homepage "https://github.com/$repo"
  version "$version"

  base = "https://github.com/$repo/releases/download/v#{version}"
  on_macos do
    on_arm do
      url "#{base}/rex-workspaces-aarch64-apple-darwin.tar.gz"
      sha256 "$(sum aarch64-apple-darwin)"
    end
    on_intel do
      url "#{base}/rex-workspaces-x86_64-apple-darwin.tar.gz"
      sha256 "$(sum x86_64-apple-darwin)"
    end
  end
  on_linux do
    on_arm do
      url "#{base}/rex-workspaces-aarch64-unknown-linux-musl.tar.gz"
      sha256 "$(sum aarch64-unknown-linux-musl)"
    end
    on_intel do
      url "#{base}/rex-workspaces-x86_64-unknown-linux-musl.tar.gz"
      sha256 "$(sum x86_64-unknown-linux-musl)"
    end
  end

  def install
    libexec.install Dir["*"]
    bin.install_symlink libexec/"bin/rex-workspaces"
  end

  def caveats
    <<~EOS
      To add rex-workspaces to Rex, run:
        rex-workspaces install
      Before brew uninstall, run:
        rex-workspaces uninstall
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/rex-workspaces --version")
    assert_path_exists libexec/"init.lua"
  end
end
RUBY
