#!/bin/sh
# Installs the latest neorex release.
#   curl -fsSL https://raw.githubusercontent.com/alexrlocke/neorex/main/install.sh | sh
# NEOREX_VERSION=v0.1.0 picks a release, NEOREX_HOME sets where it's unpacked
# (default ~/.local/share/neorex), BIN_DIR where the neorex link goes
# (default ~/.local/bin).
set -eu

repo="alexrlocke/neorex"
# minisign public key that release tarballs are signed with
pubkey="RWTUrMrkIYNmaNjwVEClcft4M6dHuMfeGANG4UjMbsjqbQQy7ngYtsD1"

case "$(uname -s)" in
  Linux) os=linux ;;
  Darwin) os=macos ;;
  *) echo "neorex: unsupported OS $(uname -s)" >&2; exit 1 ;;
esac
case "$(uname -m)" in
  x86_64 | amd64) arch=x86_64 ;;
  arm64 | aarch64) arch=aarch64 ;;
  *) echo "neorex: unsupported architecture $(uname -m)" >&2; exit 1 ;;
esac

name="neorex-$arch-$os"
dest="${NEOREX_HOME:-$HOME/.local/share/neorex}"
bindir="${BIN_DIR:-$HOME/.local/bin}"
if [ -n "${NEOREX_VERSION:-}" ]; then
  base="https://github.com/$repo/releases/download/$NEOREX_VERSION"
else
  base="https://github.com/$repo/releases/latest/download"
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "downloading $name"
curl -fsSL -o "$tmp/$name.tar.gz" "$base/$name.tar.gz"
curl -fsSL -o "$tmp/checksums.txt" "$base/checksums.txt"

expected=$(awk -v f="$name.tar.gz" '$2 == f { print $1 }' "$tmp/checksums.txt")
if command -v sha256sum >/dev/null 2>&1; then
  actual=$(sha256sum "$tmp/$name.tar.gz" | awk '{ print $1 }')
else
  actual=$(shasum -a 256 "$tmp/$name.tar.gz" | awk '{ print $1 }')
fi
if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
  echo "neorex: checksum mismatch for $name.tar.gz" >&2
  exit 1
fi

# The checksum only catches a broken download; the signature shows the
# tarball came from a neorex release. Checked when minisign is installed.
if command -v minisign >/dev/null 2>&1; then
  curl -fsSL -o "$tmp/$name.tar.gz.minisig" "$base/$name.tar.gz.minisig"
  if ! minisign -V -q -P "$pubkey" -m "$tmp/$name.tar.gz"; then
    echo "neorex: signature check failed for $name.tar.gz" >&2
    exit 1
  fi
  echo "signature verified"
else
  echo "note: install minisign to also verify the release signature"
fi

tar -xzf "$tmp/$name.tar.gz" -C "$tmp"
rm -rf "$dest"
mkdir -p "$(dirname "$dest")" "$bindir"
mv "$tmp/$name" "$dest"
ln -sf "$dest/bin/neorex" "$bindir/neorex"

echo "installed $bindir/neorex"
echo "colorscheme and lualine theme: $dest/runtime"
case ":$PATH:" in
  *":$bindir:"*) ;;
  *) echo "note: $bindir is not on your PATH" ;;
esac
