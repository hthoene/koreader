#!/usr/bin/env bash
#
# Build a KOReader release for Windows using Docker: e.g. with Docker Desktop
# on Windows (from Git Bash or WSL), but any Linux host works too.
#
# The build runs in a Docker volume (faster than a bind mount from a Windows
# file system, and symbolic links friendly): the sources of this checkout are
# synchronized into it (ignored files, like build outputs, are kept there for
# incremental builds), and the resulting release archives are copied back.
#
# Usage: platform/win32/build.sh [KODEV_RELEASE_OPTIONS]…
#
# Environment variables:
# - KOREADER_WIN32_IMAGE: toolchain image (default: `koreader/kowin32`)
# - KOREADER_WIN32_VOLUME: build volume (default: `koreader-win32-build`)

set -eo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

image="${KOREADER_WIN32_IMAGE:-koreader/kowin32}"
volume="${KOREADER_WIN32_VOLUME:-koreader-win32-build}"

if grep -q $'\r' kodev; then
    cat 1>&2 <<'EOF'
ERROR: this checkout uses CRLF line endings, which the build system does not support.

Use `git clone -c core.autocrlf=false …`, or convert the existing checkout with:

    git config core.autocrlf false
    git submodule foreach --recursive git config core.autocrlf false
    git rm -rq --cached . && git reset -q --hard
    git submodule foreach --recursive 'git rm -rq --cached . && git reset -q --hard'
EOF
    exit 1
fi

src="${PWD}"
if [[ "${OSTYPE}" == msys || "${OSTYPE}" == cygwin ]]; then
    # Git Bash: use a Windows path for the bind mount, and don't mangle container paths.
    export MSYS_NO_PATHCONV=1
    src="$(pwd -W)"
fi

docker build --tag "${image}" platform/win32
docker volume create "${volume}" >/dev/null
docker run --rm --user root --volume "${volume}:/build" "${image}" chown ko:ko /build

docker run --rm --init \
    --volume "${src}:/src:ro" \
    --volume "${volume}:/build" \
    --env CCACHE_DIR=/build/.ccache \
    "${image}" bash -eo pipefail -c '
        git config --global --add safe.directory "*"
        rsync -a --delete --filter=":- .gitignore" --exclude=/.ccache /src/ /build/koreader/
        cd /build/koreader
        rm -f koreader-win32-*.zip koreader-win32-*-setup.exe
        ./kodev release "$@" win32
    ' bash "$@"

# Copy the release archives back.
container="$(docker create --volume "${volume}:/build" "${image}")"
trap 'docker rm "${container}" >/dev/null' EXIT
for artifact in $(docker run --rm --volume "${volume}:/build" "${image}" \
                  sh -c 'cd /build/koreader && ls koreader-win32-*.zip koreader-win32-*-setup.exe'); do
    docker cp "${container}:/build/koreader/${artifact}" .
    echo "${artifact}"
done
