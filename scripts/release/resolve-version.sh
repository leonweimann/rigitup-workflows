#!/usr/bin/env bash
set -euo pipefail

die()
{
	echo "error: $*" >&2
	exit 1
}

[ -n "${TAG:-}" ] || die "TAG is required"
[ -n "${GITHUB_OUTPUT:-}" ] || die "GITHUB_OUTPUT is required"
[ -n "${GITHUB_REPOSITORY:-}" ] || die "GITHUB_REPOSITORY is required"

if [[ ! "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
	die "'$TAG' is not a vMAJOR.MINOR.PATCH tag"
fi

version=${TAG#v}
core=${version%%-*}
major=${core%%.*}
minor=$(cut -d. -f1-2 <<< "$core")
prerelease=false
[[ "$version" == *-* ]] && prerelease=true
namespace=$(tr '[:upper:]' '[:lower:]' <<< "$GITHUB_REPOSITORY")

{
	echo "tag=$TAG"
	echo "version=$version"
	echo "core=$core"
	echo "major=$major"
	echo "minor=$minor"
	echo "prerelease=$prerelease"
	echo "namespace=$namespace"
} >> "$GITHUB_OUTPUT"
