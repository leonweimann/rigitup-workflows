#!/usr/bin/env bash
set -euo pipefail

die()
{
	echo "error: $*" >&2
	exit 1
}

for name in SHA VERSION TAG NAMESPACE APP MANIFEST_PATH GITHUB_OUTPUT; do
	[ -n "${!name:-}" ] || die "$name is required"
done
[[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || die "SHA must be a full commit SHA"

repository="ghcr.io/$NAMESPACE/$APP"
reference="$repository:sha-$SHA"

inspection=$(mktemp "${RUNNER_TEMP:-/tmp}/image-inspect.XXXXXX")
trap 'rm -f "$inspection"' EXIT
docker buildx imagetools inspect "$reference" > "$inspection" \
	|| die "candidate image $reference does not exist"
grep -Eq 'linux/amd64|Platform:[[:space:]]+linux/amd64' "$inspection" \
	|| die "candidate image $reference has no linux/amd64 manifest"

digest=$(docker buildx imagetools inspect "$reference" --format '{{.Manifest.Digest}}')
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "$reference returned invalid digest '$digest'"

jq -S -n \
	--arg version "$VERSION" \
	--arg tag "$TAG" \
	--arg commit "$SHA" \
	--arg app "$APP" \
	--arg repository "$repository" \
	--arg digest "$digest" \
	'{
      commit: $commit,
      images: { ($app): { digest: $digest, repository: $repository } },
      signing: {
        build_provenance: true,
        sbom: true
      },
      tag: $tag,
      version: $version
    }' > "$MANIFEST_PATH"

echo "digest=$digest" >> "$GITHUB_OUTPUT"
echo "$APP=$repository@$digest"
