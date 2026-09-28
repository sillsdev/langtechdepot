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
set -eu

here=$(cd "$(dirname "$0")" && pwd)
head="$here/setup-langtechdepot.bat.in"
payload="$here/setup-langtechdepot.ps1"
out=${1:-"$here/setup-langtechdepot.bat"}
marker='#--LANGTECHDEPOT-PS1-PAYLOAD-BELOW--#'

# CMD misreads a .bat with LF-only line endings, so both halves must be CRLF.
# .gitattributes checks them out that way; this catches an editor undoing it.
for f in "$head" "$payload"; do
    if ! LC_ALL=C awk '!/\r$/ { bad = 1; exit } END { exit bad }' "$f"; then
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

cat "$head" "$payload" > "$out"
echo "built $out"
