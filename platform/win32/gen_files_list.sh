#!/usr/bin/env bash
#
# Generate the NSIS commands to remove the files of a release directory
# (used by the uninstaller, so it only removes what was installed).
#
# Usage: gen_files_list.sh RELEASE_DIR >files_list.nsh

# NOTE: `$INSTDIR` is a NSIS variable.
# shellcheck disable=SC2016

set -eo pipefail

cd "$1"

# NOTE: in NSIS strings, `$` must be escaped as `$$`.
escape() {
    sed -e 's|^\./||' -e 's|/|\\|g' -e 's|\$|$$|g'
}

# Files.
find . -type f | LC_ALL=C sort | escape | sed -e 's|.*|Delete "$INSTDIR\\&"|'
# Directories, deepest first (`RMDir` only removes empty directories).
find . -mindepth 1 -type d | LC_ALL=C sort -r | escape | sed -e 's|.*|RMDir "$INSTDIR\\&"|'
