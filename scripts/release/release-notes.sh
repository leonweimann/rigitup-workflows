#!/usr/bin/env bash
set -euo pipefail

die()
{
	echo "error: $*" >&2
	exit 1
}

for name in GH_TOKEN GITHUB_REPOSITORY TAG APP MANIFEST_PATH OUTPUT_PATH; do
	[ -n "${!name:-}" ] || die "$name is required"
done
[ -f "$MANIFEST_PATH" ] || die "$MANIFEST_PATH does not exist"

generated=$(mktemp "${RUNNER_TEMP:-/tmp}/release-notes.XXXXXX")
trap 'rm -f "$generated"' EXIT
gh api "repos/$GITHUB_REPOSITORY/releases/generate-notes" \
	-f tag_name="$TAG" --jq .body > "$generated"

repository=$(jq -r --arg app "$APP" '.images[$app].repository' "$MANIFEST_PATH")
digest=$(jq -r --arg app "$APP" '.images[$app].digest' "$MANIFEST_PATH")

{
	cat "$generated"
	echo
	echo "## Container image"
	echo
	echo "Die Deployment-Referenz ist inhaltsadressiert (Linux/AMD64):"
	echo
	echo "| App | Unveränderliche Referenz |"
	echo "| --- | --- |"
	echo "| \`$APP\` | \`$repository@$digest\` |"
	echo
	echo "Maschinenlesbar steht dasselbe in der angehängten \`release-manifest.json\`."
} > "$OUTPUT_PATH"
