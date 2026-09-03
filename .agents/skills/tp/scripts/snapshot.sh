#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
    echo "usage: snapshot.sh before|after ITEM" >&2
    exit 2
fi

phase=$1
item=$2

case "$phase" in
    before|after) ;;
    *)
        echo "phase must be 'before' or 'after'" >&2
        exit 2
        ;;
esac

case "$item" in
    *[!A-Za-z0-9._-]*|'')
        echo "item must contain only letters, digits, period, underscore, or hyphen" >&2
        exit 2
        ;;
esac

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(git -C "$script_dir" rev-parse --show-toplevel)
current_root=$(git rev-parse --show-toplevel)

if [ "$repo_root" != "$current_root" ]; then
    echo "run this helper from the TP skill's repository" >&2
    exit 1
fi

if ! git -C "$repo_root" symbolic-ref -q HEAD >/dev/null; then
    echo "refusing to snapshot a detached HEAD" >&2
    exit 1
fi

if [ -n "$(git -C "$repo_root" diff --name-only --diff-filter=U)" ]; then
    echo "refusing to snapshot unresolved conflicts" >&2
    exit 1
fi

for operation_ref in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD; do
    if git -C "$repo_root" rev-parse -q --verify "$operation_ref" >/dev/null; then
        echo "refusing to snapshot while $operation_ref exists" >&2
        exit 1
    fi
done

git_dir=$(git -C "$repo_root" rev-parse --absolute-git-dir)
for operation_dir in rebase-apply rebase-merge; do
    operation_path="$git_dir/$operation_dir"
    if [ -d "$operation_path" ]; then
        echo "refusing to snapshot during $operation_dir" >&2
        exit 1
    fi
done

git -C "$repo_root" add -A -- .
git -C "$repo_root" commit --allow-empty -m "TP $phase: $item" >&2
git -C "$repo_root" rev-parse HEAD
