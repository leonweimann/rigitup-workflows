#!/usr/bin/env bash
set -euo pipefail

die()
{
	echo "error: $*" >&2
	exit 1
}

[ -n "${VERSION:-}" ] || die "VERSION is required"
cd "$(git rev-parse --show-toplevel)"

core=${VERSION%%-*}

# Read [project].version without assuming fixed spacing around "=". A formatter
# that aligns assignments produces `version         = "0.0.1"`, which defeats
# any pattern written for a single space.
have=$(awk -F'"' '
	/^\[/ { in_project = ($0 == "[project]") }
	in_project && /^[[:space:]]*version[[:space:]]*=/ { print $2; exit }
' pyproject.toml)

if [ "$have" != "$core" ]; then
	echo "::error file=pyproject.toml::version is ${have:-missing} but expected $core"
	exit 1
fi

echo "pyproject.toml declares $have"
