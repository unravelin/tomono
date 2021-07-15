#!/bin/bash

# Merge multiple repositories into one big monorepo. Migrates every branch in
# every subrepo to the eponymous branch in the monorepo, with all files
# (including in the history) rewritten to live under a subdirectory.
#
# To use a separate temporary directory while migrating, set the GIT_TMPDIR
# envvar.
#
# To access the individual functions instead of executing main, source this
# script from bash instead of executing it.

${DEBUGSH:+set -x}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	is_script=true
	set -eu -o pipefail
else
	is_script=false
fi

# Default name of the mono repository (override with envvar)
: "${MONOREPO_NAME=core}"

function read_repositories {
	sed -e 's/#.*//' | grep .
}

# List all branches for a given remote
function remote-branches {
	git ls-remote --heads --refs "$1" | sed 's#.*refs/heads/##'
}

# List all tags for a given remote
function remote-tags {
	git ls-remote --tags --refs "$1" | sed 's#.*refs/tags/##'
}

# Wrapper for fetching further information about a tag
function tag-info {
	git for-each-ref "refs/tags/${1}" --format="%(${2})"
}

# Create a monorepository in a directory "core". Read repositories from STDIN:
# one line per repository, with two space separated values:
#
# 1. The (git cloneable) location of the repository
# 2. The name of the target directory in the core repository
function create-mono {
	# Pretty risky, check double-check!
	if [[ "${1:-}" == "--continue" ]]; then
		if [[ ! -d "$MONOREPO_NAME" ]]; then
			echo "--continue specified, but nothing to resume" >&2
			exit 1
		fi
		pushd "$MONOREPO_NAME"
	else
		if [[ -d "$MONOREPO_NAME" ]]; then
			echo "Target repository directory ${MONOREPO_NAME} already exists." >&2
			return 1
		fi
		mkdir "$MONOREPO_NAME"
		pushd "$MONOREPO_NAME"
		git init
	fi

	read_repositories | while read -r repo name folder; do
		if [[ -z "$name" ]]; then
			echo "pass REPOSITORY NAME pairs on stdin" >&2
			return 1
		elif [[ "$name" = */* ]]; then
			echo "Forward slash '/' not supported in repo names: ${name}" >&2
			return 1
		fi

                if [[ -z "$folder" ]]; then
			folder="$name"
                fi

		echo "Merging in ${repo}..." >&2
		git remote add "$name" "$repo"
		echo "Fetching ${name}..." >&2
		git fetch -q "$name"

		# Copy tags including their proper content
		remote-tags "$name" | while read -r tag; do
			echo "Copying tag ${tag} over to ${name}/${tag}..."

			(
				GIT_COMMITTER_NAME="$(tag-info "$tag" "taggername")"
				GIT_COMMITTER_EMAIL="$(tag-info "$tag" "taggeremail")"
				GIT_COMMITTER_DATE="$(tag-info "$tag" "taggerdate")"

				contents=$(tag-info "$tag" "contents")
				if [[ -n "$contents" ]]; then
					git tag -a -m "$contents" "${name}/${tag}" "${tag}^{}"
				else
					git tag "${name}/${tag}" "${tag}^{}"
				fi
			)

			git tag -d "$tag"
		done

		# Merge every branch from the sub repo into the mono repo, into a
		# branch of the same name (create one if it doesn't exist).
		remote-branches "$name" | while read -r branch; do
			if git rev-parse -q --verify "$branch"; then
				# Branch already exists, just check it out (and clean up the working dir)
				git checkout -q "$branch"
				git checkout -q -- .
				git clean -f -d
			else
				# Create a fresh branch with an empty root commit"
				git checkout -q --orphan "$branch"
				# The ignore unmatch is necessary when this was a fresh repo
				git rm -rfq --ignore-unmatch .
				git commit -q --allow-empty -m "Root commit for $branch branch"
			fi

			git merge -q --no-commit -s ours "${name}/${branch}" --allow-unrelated-histories
			git read-tree --prefix="${folder}/" "${name}/${branch}"
			git commit -q --no-verify --allow-empty -m "Merge branch '${name}/${branch}' into '${branch}'"
		done
	done

	git checkout -q "$(git config --default "main" --get init.defaultBranch)"
	git checkout -q .
}

if [[ "$is_script" == "true" ]]; then
	create-mono "${1:-}"
fi
