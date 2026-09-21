#!/usr/bin/env bash
set -euo pipefail

install_dir="${BASEHARBOR_INSTALL_DIR:-$PWD/.tools/bin}"
source_ref="${BASEHARBOR_SOURCE_REF:-}"
version="${BASEHARBOR_VERSION:-}"
mkdir -p "$install_dir"

if [ -n "$source_ref" ]; then
  workdir="${BASEHARBOR_SOURCE_DIR:-/tmp/baseharbor-candidate}"
  rm -rf "$workdir"
  git clone --filter=blob:none --no-checkout https://github.com/mcpdev80/baseharbor.git "$workdir"
  git -C "$workdir" fetch --depth 1 origin "$source_ref"
  git -C "$workdir" checkout --detach FETCH_HEAD

  (
    cd "$workdir"
    CGO_ENABLED=0 go build -trimpath -o "$install_dir/baha" ./cmd/baha

    mkdir -p /tmp/baseharbor-runtime-image
    cp "$install_dir/baha" /tmp/baseharbor-runtime-image/baha
    cp deploy/control-plane/Dockerfile.binary /tmp/baseharbor-runtime-image/Dockerfile
    docker build --pull -t baseharbor-runtime:demo-candidate /tmp/baseharbor-runtime-image
  )

  export BASEHARBOR_RUNTIME_IMAGE=baseharbor-runtime:demo-candidate
  printf 'Prepared BaseHarbor candidate %s from source.\n' "$source_ref"
  "$install_dir/baha" version
  exit 0
fi

[ -n "$version" ] || {
  echo "BASEHARBOR_VERSION or BASEHARBOR_SOURCE_REF is required" >&2
  exit 1
}

case "$version" in
  v*) ;;
  *) version="v$version" ;;
esac

curl -fsSL --retry 3 "https://raw.githubusercontent.com/mcpdev80/baseharbor/$version/scripts/install.sh" -o /tmp/baseharbor-install.sh
chmod 700 /tmp/baseharbor-install.sh
BASEHARBOR_VERSION="$version" BASEHARBOR_INSTALL_DIR="$install_dir" /tmp/baseharbor-install.sh
"$install_dir/baha" version
