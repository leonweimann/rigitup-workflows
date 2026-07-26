#!/usr/bin/env bash
set -euo pipefail

die()
{
	echo "error: $*" >&2
	exit 1
}

cd "$(git rev-parse --show-toplevel)"

if [ -n "${GITHUB_REPOSITORY:-}" ]; then
	repo=$GITHUB_REPOSITORY
else
	repo=$(git remote get-url origin \
		| sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')
fi
[ -n "$repo" ] || die "could not determine the repository name"

# A reusable workflow references this repository's own actions absolutely,
# because a relative path would resolve against the *calling* repository. Those
# references are pinned, so they can silently lag behind the files they point
# at — a pin from before a script existed fails with exit 127 at runtime, and a
# tag freezes that state forever.
#
# Reference point: the newest commit that touched an action or a script.
# Workflow files are deliberately excluded, so that the commit which updates
# the pins does not overtake itself.
expected=$(git log -1 --format=%H -- .github/actions scripts)
[ -n "$expected" ] || die "could not determine the newest content commit"

echo "actions and scripts are at ${expected:0:7}"

bad=0
while IFS= read -r hit; do
	file=${hit%%:*}
	rest=${hit#*:}
	lineno=${rest%%:*}

	ref=$(sed -E 's/.*uses:[[:space:]]*//; s/[[:space:]]*#.*$//' <<< "$hit")
	path=${ref#"$repo/"}
	path=${path%@*}
	sha=${ref##*@}

	if [ ! -e "$path" ]; then
		echo "::error file=$file,line=$lineno::$path does not exist in this repository"
		bad=1
		continue
	fi

	if [ "$sha" != "$expected" ]; then
		echo "::error file=$file,line=$lineno::$path is pinned to ${sha:0:7}, but actions and scripts are at ${expected:0:7}"
		bad=1
		continue
	fi

	echo "ok $path@${sha:0:7}"
done < <(grep -rn "uses:[[:space:]]*$repo/" .github/workflows .github/actions || true)

if [ "$bad" -ne 0 ]; then
	cat >&2 <<-EOF

		Update every reference above to $expected.

		Keep it a separate commit that touches only .github/workflows — a commit
		that changes an action and its pin at once makes itself the newest
		content commit, and the pin inside it points at the one before.
	EOF
	exit 1
fi

echo "every self reference points at the current content"
