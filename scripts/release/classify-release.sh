#!/usr/bin/env bash
set -euo pipefail

die()
{
	echo "error: $*" >&2
	exit 1
}

for name in GH_TOKEN GITHUB_REPOSITORY GITHUB_OUTPUT SHA; do
	[ -n "${!name:-}" ] || die "$name is required"
done

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

echo "is_release=false" >> "$GITHUB_OUTPUT"

prs=$(gh api "repos/$GITHUB_REPOSITORY/commits/$SHA/pulls")
release_prs=$(jq '[.[] | select(.merged_at != null) | select(.base.ref == "main") | select(any(.labels[]?; .name == "deployment"))]' <<< "$prs")
count=$(jq 'length' <<< "$release_prs")

[ "$count" -le 1 ] || die "commit $SHA is associated with multiple deployment-labelled release PRs"
[ "$count" -eq 1 ] || exit 0

# No author check: this path has no bot identity. The release PR is recognised
# by what it *is* — merge commit, branch name, title, changed paths, version
# agreement — not by who opened it. Those checks now carry alone.
pr=$(jq '.[0]' <<< "$release_prs")
number=$(jq -r '.number' <<< "$pr")
head=$(jq -r '.head.ref' <<< "$pr")
title=$(jq -r '.title' <<< "$pr")
merge_sha=$(jq -r '.merge_commit_sha' <<< "$pr")

[ "$merge_sha" = "$SHA" ] || die "release PR #$number merged as $merge_sha, expected $SHA"
[[ "$head" =~ ^release/v([0-9]+\.[0-9]+\.[0-9]+)$ ]] || die "release PR #$number has invalid branch '$head'"
branch_version=${BASH_REMATCH[1]}
[[ "$title" =~ ^release\((patch|minor|major)\):\ v([0-9]+\.[0-9]+\.[0-9]+)$ ]] || die "release PR #$number has invalid title '$title'"
part=${BASH_REMATCH[1]}
version=${BASH_REMATCH[2]}
[ "$version" = "$branch_version" ] || die "release title and branch versions disagree"

files=$(gh pr view "$number" --repo "$GITHUB_REPOSITORY" --json files --jq '.files[].path')
while IFS= read -r path; do
	case "$path" in
		pyproject.toml | uv.lock) ;;
		*) die "release PR #$number changed forbidden path '$path'" ;;
	esac
done <<< "$files"

# Resolved against this script, not the working directory: the checkout here is
# the calling repository, while the scripts arrive through an action.
VERSION="$version" "$here/check-manifests.sh"

if [ "${ALLOW_EXISTING_RELEASE:-false}" != true ]; then
	if gh api "repos/$GITHUB_REPOSITORY/git/ref/tags/v$version" > /dev/null 2>&1; then
		die "tag v$version already exists"
	fi
	if gh release view "v$version" --repo "$GITHUB_REPOSITORY" > /dev/null 2>&1; then
		die "release v$version already exists"
	fi
fi

{
	echo "is_release=true"
	echo "part=$part"
	echo "version=$version"
	echo "tag=v$version"
	echo "pr_number=$number"
} >> "$GITHUB_OUTPUT"
