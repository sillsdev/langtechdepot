#!/bin/sh
# Prints the LangTechDepot version, worked out from git: the one place the
# number lives is the release tag (v1.0.1, v1.1.0, ...). Used by build-bat.sh
# (for the installer) and by the Pages workflow (for the download page).
#
#   1.0.1                 the client files are exactly as tagged v1.0.1
#   1.0.1+dev.ad02872     client files changed since v1.0.1 and not tagged yet;
#                         ad02872 is the commit they were built from
#   dev                   no git, or no v* tag at all
#
# Only client/ is compared with the tag, so a website-only change published
# after a release still says 1.0.1 - the installer it offers is unchanged.
set -eu
here=$(cd "$(dirname "$0")" && pwd)

tag=$(git -C "$here" describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null) || {
    echo dev
    exit 0
}
version=${tag#v}

# Compares the tagged client/ with the files on disk, so an uncommitted local
# edit counts as a change too.
if ! git -C "$here" diff --quiet "$tag" -- . 2>/dev/null; then
    version="$version+dev.$(git -C "$here" rev-parse --short HEAD)"
fi
echo "$version"
