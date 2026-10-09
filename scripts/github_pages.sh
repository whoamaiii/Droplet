#!/bin/bash
# GitHub Pages addresses for a repository (used by release.sh and publish.sh):
#
#   github_pages.sh base OWNER/REPO        https://owner.github.io, or
#                                          https://owner.github.io/REPO for a project repository
#   github_pages.sh folder OWNER/REPO URL  the folder in the repository that is served at URL
#                                          (empty for the top); fails if URL is not on its site
set -euo pipefail
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
base() {
    local owner="${1%%/*}" name="${1#*/}"
    if [ "$(lower "$name")" = "$(lower "$owner").github.io" ]; then
        echo "https://$(lower "$owner").github.io"
    else
        echo "https://$(lower "$owner").github.io/$name"
    fi
}
case "${1:-}" in
    base) base "$2" ;;
    folder)
        site="$(base "$2")"
        url="${3%/}"
        case "$url" in
            "$site") echo "" ;;
            "$site"/*) echo "${url#"$site"/}" ;;
            *) exit 1 ;;
        esac ;;
    *) echo "usage: github_pages.sh base OWNER/REPO | folder OWNER/REPO URL" >&2; exit 2 ;;
esac
