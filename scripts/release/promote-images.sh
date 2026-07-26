#!/usr/bin/env bash
set -euo pipefail

die()
{
	echo "error: $*" >&2
	exit 1
}

for name in MANIFEST_PATH APP VERSION MAJOR MINOR PRERELEASE; do
	[ -n "${!name:-}" ] || die "$name is required"
done
[ -f "$MANIFEST_PATH" ] || die "$MANIFEST_PATH does not exist"

inspect_digest()
{
	docker buildx imagetools inspect "$1" --format '{{.Manifest.Digest}}' 2> /dev/null
}

repository=$(jq -r --arg app "$APP" '.images[$app].repository' "$MANIFEST_PATH")
digest=$(jq -r --arg app "$APP" '.images[$app].digest' "$MANIFEST_PATH")
if [ -z "$repository" ] || [ "$repository" = null ]; then
	die "$MANIFEST_PATH has no entry for $APP"
fi

# The exact version tag is immutable. If it already exists it must agree, and
# it is checked before anything is mutated.
exact="$repository:$VERSION"
if current=$(inspect_digest "$exact"); then
	[ "$current" = "$digest" ] || die "$exact already points to $current, expected $digest"
else
	docker buildx imagetools create --tag "$exact" "$repository@$digest"
	current=$(inspect_digest "$exact")
fi
[ "$current" = "$digest" ] || die "$exact resolved to $current after promotion, expected $digest"
echo "verified $exact -> $digest"

if [ "$PRERELEASE" = true ]; then
	echo "prerelease: floating aliases stay where they are"
	exit 0
fi

for alias in "$MINOR" "$MAJOR" latest; do
	docker buildx imagetools create --tag "$repository:$alias" "$repository@$digest"
	current=$(inspect_digest "$repository:$alias")
	[ "$current" = "$digest" ] || die "$repository:$alias resolved to $current, expected $digest"
	echo "verified $repository:$alias -> $digest"
done
