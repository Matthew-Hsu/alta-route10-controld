#!/bin/sh
# Fail when the documentation links to an issue that is closed, or when a pull
# request closes an issue the documentation still links to.
#
# The README links a known limit to the issue tracking it. Once that issue is
# closed the sentence around the link is usually no longer true, and nothing
# else notices: the suite never reads prose for meaning. The second check
# catches it in the pull request that does the closing, while the author still
# has the paragraph in front of them. The first catches an issue closed any
# other way, at the next run.
#
# Usage: check-issue-refs.sh [--list] [file...]
#   With no files, README.md and docs/*.md are checked.
#   --list prints each citation as file:line:number and looks nothing up.
#
# Needs gh, signed in (GH_TOKEN in CI). PR_BODY, when set, is the body of the
# pull request under test. GITHUB_REPOSITORY names the repository, as Actions
# sets it.
#
# A citation is a link of the form github.com/<owner>/<repo>/issues/<number>.
# A bare #57 in a markdown file is not a link and is not seen here.

REPO="${GITHUB_REPOSITORY:-Matthew-Hsu/alta-route10-controld}"

LIST=0
if [ "${1:-}" = "--list" ]; then LIST=1; shift; fi
if [ "$#" -eq 0 ]; then set -- README.md docs/*.md; fi

# Every citation as file:line:number. grep -n with -H keeps the file name even
# when only one file is given.
citations() {
    grep -HniE "github\.com/${REPO}/issues/[0-9]+" "$@" 2>/dev/null \
        | while IFS= read -r _line; do
            _at="${_line%%:*}"; _rest="${_line#*:}"; _ln="${_rest%%:*}"
            printf '%s\n' "$_rest" \
                | grep -oiE "github\.com/${REPO}/issues/[0-9]+" \
                | sed 's#.*/##' \
                | while IFS= read -r _n; do printf '%s:%s:%s\n' "$_at" "$_ln" "$_n"; done
        done
}

# Where number $1 is cited, as "file:line" joined by spaces.
cited_at() {
    printf '%s\n' "$CITES" | awk -F: -v n="$1" '$3 == n { printf "%s%s:%s", sep, $1, $2; sep = " " }'
}

CITES="$(citations "$@")"

if [ "$LIST" = "1" ]; then
    [ -n "$CITES" ] && printf '%s\n' "$CITES"
    exit 0
fi

fail=0
for n in $(printf '%s\n' "$CITES" | awk -F: 'NF { print $3 }' | sort -un); do
    if ! state="$(gh api "repos/${REPO}/issues/${n}" --jq .state 2>/dev/null)"; then
        echo "could not look up #${n} — cited at $(cited_at "$n")"
        fail=1
    elif [ "$state" = "closed" ]; then
        echo "#${n} is closed — still cited at $(cited_at "$n")"
        fail=1
    else
        echo "#${n} is ${state}"
    fi
done

# GitHub closes an issue on merge when the body says close, fix or resolve, in
# any tense, followed by its number.
if [ -n "${PR_BODY:-}" ]; then
    for n in $(printf '%s\n' "$PR_BODY" \
            | grep -oiE '(^|[^[:alnum:]])(close[sd]?|fix(e[sd])?|resolve[sd]?):? +#[0-9]+' \
            | sed 's/.*#//' | sort -un); do
        _where="$(cited_at "$n")"
        if [ -n "$_where" ]; then
            echo "this pull request closes #${n} — still cited at ${_where}"
            fail=1
        fi
    done
fi

exit "$fail"
