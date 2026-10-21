#!/usr/bin/env bash
set -euo pipefail

if command -v git >/dev/null 2>&1; then
  exit 0
fi

root="${RUNNER_TEMP:-/tmp}/setup-git"
rm -rf "$root"
mkdir -p "$root/src" "$root/home"

micromamba_url="https://github.com/mamba-org/micromamba-releases/releases/download/2.9.0-0/micromamba-linux-64"
readonly micromamba_sha256=366cd9cd8be14df1ab8ed50352a82111082a36686b2d389fdb79a92c3fafb3e3
curl -fsSL -o "$root/src/micromamba" "$micromamba_url"
actual=$(sha256sum "$root/src/micromamba" | cut -d' ' -f1)
if [ "$actual" != "$micromamba_sha256" ]; then
  echo "checksum mismatch for micromamba: expected $micromamba_sha256, got $actual" >&2
  exit 1
fi
chmod +x "$root/src/micromamba"
HOME="$root/home" "$root/src/micromamba" create -y -p "$root/git" -c conda-forge "git=2.56.0=pl5440h3795e67_0" --root-prefix "$root/mamba"

"$root/git/bin/git" --version
echo "$root/git/bin" >> "$GITHUB_PATH"
