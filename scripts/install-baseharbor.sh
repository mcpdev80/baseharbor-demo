#!/usr/bin/env bash
set -euo pipefail

install_dir="${BASEHARBOR_INSTALL_DIR:-$PWD/.tools/bin}"
source_ref="${BASEHARBOR_SOURCE_REF:-}"
version="${BASEHARBOR_VERSION:-}"
container_cli="${BASEHARBOR_TEST_RUNTIME:-}"
if [ -z "$container_cli" ]; then
  if command -v docker >/dev/null 2>&1; then
    container_cli=docker
  elif command -v podman >/dev/null 2>&1; then
    container_cli=podman
  else
    echo "Neither docker nor podman is available." >&2
    exit 1
  fi
fi
mkdir -p "$install_dir"

container_runtime() {
  if [ "$(basename "$container_cli")" = "podman" ]; then
    env -u XDG_CONFIG_HOME -u XDG_DATA_HOME "$container_cli" "$@"
    return
  fi
  "$container_cli" "$@"
}

prebuilt_binary="${BASEHARBOR_PREBUILT_BINARY:-}"
if [ -n "$prebuilt_binary" ]; then
  [ -x "$prebuilt_binary" ] || {
    echo "BASEHARBOR_PREBUILT_BINARY is not executable: $prebuilt_binary" >&2
    exit 1
  }
  [ -n "${BASEHARBOR_RUNTIME_IMAGE:-}" ] || {
    echo "BASEHARBOR_RUNTIME_IMAGE is required with BASEHARBOR_PREBUILT_BINARY." >&2
    exit 1
  }
  container_runtime image inspect "$BASEHARBOR_RUNTIME_IMAGE" >/dev/null 2>&1 || {
    echo "Preloaded runtime image is missing: $BASEHARBOR_RUNTIME_IMAGE" >&2
    exit 1
  }
  cp "$prebuilt_binary" "$install_dir/baha"
  chmod 0755 "$install_dir/baha"

  if [ -n "$source_ref" ]; then
    binary_version="$("$install_dir/baha" version)"
    case "$binary_version" in
      *"commit $source_ref"*) ;;
      *)
        echo "Prebuilt BaseHarbor binary does not contain requested source ref $source_ref" >&2
        exit 1
        ;;
    esac
    image_version="$(container_runtime run --rm --entrypoint /usr/local/bin/baha "$BASEHARBOR_RUNTIME_IMAGE" version)"
    case "$image_version" in
      *"commit $source_ref"*) ;;
      *)
        echo "Preloaded runtime image does not contain requested source ref $source_ref" >&2
        exit 1
        ;;
    esac
  fi

  printf 'Using prebuilt BaseHarbor candidate and preloaded runtime image.\n'
  "$install_dir/baha" version
  exit 0
fi

if [ -n "$source_ref" ]; then
  workdir="${BASEHARBOR_SOURCE_DIR:-/tmp/baseharbor-candidate}"
  runtime_image="${BASEHARBOR_RUNTIME_IMAGE:-localhost/baseharbor-runtime:demo-candidate-$source_ref}"
  rm -rf "$workdir"
  git clone --filter=blob:none --no-checkout https://github.com/mcpdev80/baseharbor.git "$workdir"
  git -C "$workdir" fetch --depth 1 origin "$source_ref"
  git -C "$workdir" checkout --detach FETCH_HEAD

  (
    cd "$workdir"
    CGO_ENABLED=0 go build -trimpath \
      -ldflags="-s -w -X main.version=dev -X main.commit=$source_ref -X main.date=unknown" \
      -o "$install_dir/baha" ./cmd/baha

    mkdir -p /tmp/baseharbor-runtime-image
    cp "$install_dir/baha" /tmp/baseharbor-runtime-image/baha
    cp deploy/control-plane/Dockerfile.binary /tmp/baseharbor-runtime-image/Dockerfile
    container_runtime build --pull --no-cache -t "$runtime_image" /tmp/baseharbor-runtime-image
    image_version="$(container_runtime run --rm --entrypoint /usr/local/bin/baha "$runtime_image" version)"
    printf 'Prepared runtime candidate image: %s\n' "$image_version"
    case "$image_version" in
      *"commit $source_ref"*) ;;
      *)
        echo "Runtime candidate image does not contain requested BaseHarbor source ref $source_ref" >&2
        exit 1
        ;;
    esac
  )

  export BASEHARBOR_RUNTIME_IMAGE="$runtime_image"
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
