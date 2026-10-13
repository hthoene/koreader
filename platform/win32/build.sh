#!/usr/bin/env bash
#
# Build a KOReader release for Windows using Docker: e.g. with Docker Desktop
# on Windows (from Git Bash or WSL), but any Linux host works too.
#
# The build runs in a Docker volume (faster than a bind mount from a Windows
# file system, and symbolic links friendly): the sources of this checkout are
# synchronized into it (files ignored by git, like build outputs, are kept there
# for incremental builds), and the resulting release archives are copied back.
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

# Initialize missing submodules (like `kodev` does), without touching the others.
init_submodules() {
    local status path
    while read -r status path _; do
        if [[ "${status}" == -* ]]; then
            git -C "$1" -c core.autocrlf=false submodule update --init -- "${path}"
            git -C "$1/${path}" config core.autocrlf false
        fi
        init_submodules "$1/${path}"
    done < <(git -C "$1" submodule status)
}
init_submodules .

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
        dst=/build/koreader
        files=/build/.sync-files
        # Repositories (the main one, and its submodules), relative to the top (with a trailing slash).
        mapfile -t repos < <(git -C /src submodule foreach --quiet --recursive "echo \"\${displaypath}/\"")
        repos=("" "${repos[@]}")
        # List the source files: tracked, or untracked but not ignored (minus submodules).
        for repo in "${repos[@]}"; do
            submodules=()
            if [[ -f "/src/${repo}.gitmodules" ]]; then
                mapfile -t submodules < <(git config --file "/src/${repo}.gitmodules" --get-regexp "\.path$" | cut -d" " -f2)
            fi
            git -C "/src/${repo}" ls-files -z --cached --others --exclude-standard |
                grep -zvxF -f <(printf "%s\n" "${submodules[@]}") |
                sed -z "s|^|${repo}|"
            # And the git metadata (needed for versioning): a git directory (synchronized
            # separately), or a file pointing to one (in the superproject git directory).
            if [[ -f "/src/${repo}.git" ]]; then
                printf "%s\0" "${repo}.git"
            fi
        done | LC_ALL=C sort -zu >"${files}"
        mkdir -p "${dst}"
        for repo in "${repos[@]}"; do
            if [[ -d "/src/${repo}.git" ]]; then
                rsync -a --delete "/src/${repo}.git/" "${dst}/${repo}.git/"
            fi
        done
        # NOTE: files deleted from the working tree, but still in the index, are deleted too.
        rsync -a --from0 --files-from="${files}" --delete-missing-args /src/ "${dst}/"
        # Remove the files that are not part of the sources (anymore): untracked and not ignored
        # (so build outputs are kept), e.g. deleted from the sources, or created by a build step.
        for repo in "${repos[@]}"; do
            git -C "${dst}/${repo}" ls-files -z --others --exclude-standard | sed -z "s|^|${repo}|"
        done | LC_ALL=C sort -zu | LC_ALL=C comm -z -23 - "${files}" | (cd "${dst}" && xargs -0r rm -f --)
        cd "${dst}"
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
