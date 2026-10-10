#!/bin/sh
# Fail when a commit message in a pull request, or the pull request's own
# description, carries a URL.
#
# CONTRIBUTING.md rules out URLs in both. A commit message is read in git log
# on a router over SSH, long after a link stops resolving, by someone who
# cannot click it. Many tools append a session link to both by default, and
# until this ran, the pull request template's checkbox was all that asked
# anyone to look.
#
# Usage: check-no-urls.sh [range]
#   range is a git revision range, such as origin/master..HEAD. Every commit
#   message in it is checked.
#
# PR_BODY, when set, is the description of the pull request under test. With
# neither a range nor PR_BODY there is nothing to check, which is an error
# rather than a pass.
#
# A URL is anything that starts with http:// or https://, in any case. An
# email address, as in a Co-Authored-By trailer, is not one.

URL_RE='https?://'

if [ -z "${1:-}" ] && [ -z "${PR_BODY:-}" ]; then
    echo "usage: check-no-urls.sh <range>, with PR_BODY set to check a description" >&2
    exit 2
fi

# The lines of stdin that carry a URL, as "line 3" or "lines 3, 7", or nothing.
url_lines() {
    grep -inE "$URL_RE" | awk -F: '{ n++; at = at sep $1; sep = ", " }
        END { if (n == 1) print "line " at; else if (n > 1) print "lines " at }'
}

fail=0
checked=0

if [ -n "${1:-}" ]; then
    if ! _revs="$(git rev-list "$1" 2>/dev/null)"; then
        echo "could not list the commits in $1 — nothing was checked"
        exit 1
    fi
    for _c in $_revs; do
        checked=$((checked + 1))
        _msg="$(git log -1 --format=%B "$_c")"
        _at="$(printf '%s\n' "$_msg" | url_lines)"
        if [ -n "$_at" ]; then
            _subj="$(printf '%s\n' "$_msg" | head -1)"
            echo "$(printf '%s' "$_c" | cut -c1-7) carries a URL — ${_at} of \"${_subj}\""
            fail=1
        fi
    done
fi

if [ -n "${PR_BODY:-}" ]; then
    _at="$(printf '%s\n' "$PR_BODY" | url_lines)"
    if [ -n "$_at" ]; then
        echo "the pull request description carries a URL — ${_at}"
        fail=1
    fi
fi

if [ "$fail" = "0" ]; then
    if [ -n "${PR_BODY:-}" ]; then
        echo "no URL in ${checked} commit message(s) or the description"
    else
        echo "no URL in ${checked} commit message(s)"
    fi
fi

exit "$fail"
