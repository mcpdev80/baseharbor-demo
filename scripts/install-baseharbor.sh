#!/usr/bin/env bash
set -euo pipefail

version="${BASEHARBOR_VERSION:-latest}"
install_dir="${BASEHARBOR_INSTALL_DIR:-$PWD/.tools/bin}"
mkdir -p "$install_dir"

if [ "$version" = "latest" ]; then
  script_ref="main"
else
  case "$version" in v*) ;; *) version="v$version" ;; esac
  script_ref="$version"
fi

curl -fsSL --retry 3 "https://raw.githubusercontent.com/mcpdev80/baseharbor/$script_ref/scripts/install.sh" -o /tmp/baseharbor-install.sh
chmod 700 /tmp/baseharbor-install.sh
BASEHARBOR_VERSION="$version" BASEHARBOR_INSTALL_DIR="$install_dir" /tmp/baseharbor-install.sh
"$install_dir/baha" version
