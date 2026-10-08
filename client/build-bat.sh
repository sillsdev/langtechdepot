#!/bin/sh
# Builds setup-langtechdepot.bat: the small CMD launcher in
# setup-langtechdepot.bat.in, followed by setup-langtechdepot.ps1 as the
# payload the launcher extracts and runs at install time.
#
# The .bat is never committed. setup-langtechdepot.ps1 is the one copy of the
# installer; this script is the only way the .bat gets made, both here and in
# the GitHub workflow that publishes it.
#
#   sh client/build-bat.sh              -> client/setup-langtechdepot.bat
#   sh client/build-bat.sh OUTPUT.bat   -> wherever you say
#
# The version number written into the .bat comes from the git tag; see
# version.sh.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
head="$here/setup-langtechdepot.bat.in"
payload="$here/setup-langtechdepot.ps1"
out=${1:-"$here/setup-langtechdepot.bat"}
marker='#--LANGTECHDEPOT-PS1-PAYLOAD-BELOW--#'

# CMD misreads a .bat with LF-only line endings, so both halves must be CRLF.
# .gitattributes checks them out that way; this catches an editor undoing it.
# BINMODE=3 stops Git Bash's gawk on Windows reading (and writing) in text
# mode, which strips the very \r this looks for; other awks ignore it.
for f in "$head" "$payload"; do
    if ! LC_ALL=C awk -v BINMODE=3 '!/\r$/ { bad = 1; exit } END { exit bad }' "$f"; then
        echo "build-bat: $f has lines without CRLF endings" >&2
        exit 1
    fi
done

# The launcher runs everything after the first marker line it finds, so the
# header must end with it and the payload must never contain it.
if [ "$(tail -n 1 "$head" | tr -d '\r')" != "$marker" ]; then
    echo "build-bat: $head must end with the line $marker" >&2
    exit 1
fi
if tr -d '\r' < "$payload" | grep -qxF "$marker"; then
    echo "build-bat: $payload contains the marker line; the launcher would cut it short" >&2
    exit 1
fi

# The version comes from the git release tag (see version.sh) and is written
# into the one line of the payload that holds it. The .ps1 itself is never
# changed: run straight from the repo it says "dev".
version=$(sh "$here/version.sh")
line='$LTD_VERSION = "dev"'
count=$(tr -d '\r' < "$payload" | grep -cxF "$line" || true)
if [ "$count" != 1 ]; then
    echo "build-bat: $payload must contain the line $line exactly once (found $count)" >&2
    exit 1
fi

{
    cat "$head"
    # Lines keep their CRLF: awk's record still ends in \r, and print adds
    # \n - given binary mode (BINMODE=3, as above). In text mode Git Bash's
    # gawk drops the \r on reading, so the version line never matches.
    awk -v BINMODE=3 -v v="$version" '{
        if ($0 == "$LTD_VERSION = \"dev\"\r") print "$LTD_VERSION = \"" v "\"\r"
        else print
    }' "$payload"
} > "$out"
echo "built $out (version $version)"
