#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: verify_log_append_only.sh BASELINE_COMMIT" >&2
    exit 2
fi

baseline_commit=$1
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(git -C "$script_dir" rev-parse --show-toplevel)
current_root=$(git rev-parse --show-toplevel)
log_path="$repo_root/AI_INTERACTIONS.md"

if [ "$repo_root" != "$current_root" ]; then
    echo "run this helper from the TP skill's repository" >&2
    exit 1
fi

git -C "$repo_root" cat-file -e "$baseline_commit^{commit}"
if ! git -C "$repo_root" merge-base --is-ancestor "$baseline_commit" HEAD; then
    echo "baseline commit is not an ancestor of HEAD" >&2
    exit 1
fi

old_log=$(mktemp "${TMPDIR:-/tmp}/tp-old-log.XXXXXX")
trap 'rm -f "$old_log"' EXIT HUP INT TERM

if git -C "$repo_root" cat-file -e "$baseline_commit:AI_INTERACTIONS.md" 2>/dev/null; then
    git -C "$repo_root" show "$baseline_commit:AI_INTERACTIONS.md" >"$old_log"
else
    : >"$old_log"
fi

if [ ! -f "$log_path" ]; then
    echo "AI_INTERACTIONS.md is missing" >&2
    exit 1
fi

old_size=$(wc -c <"$old_log" | tr -d ' ')
new_size=$(wc -c <"$log_path" | tr -d ' ')

if [ "$new_size" -le "$old_size" ]; then
    echo "AI_INTERACTIONS.md did not grow" >&2
    exit 1
fi

if [ "$old_size" -gt 0 ] && ! head -c "$old_size" "$log_path" | cmp -s "$old_log" -; then
    echo "existing AI_INTERACTIONS.md content was changed" >&2
    exit 1
fi

echo "AI_INTERACTIONS.md is append-only relative to $baseline_commit"
