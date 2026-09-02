# Contributing

## Commit messages

This project follows [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/):

```
type(scope): subject

body explaining what was wrong and why this is the fix

Co-Authored-By: ...
```

**Types used here:** `fix`, `feat`, `refactor`, `docs`, `test`, `ci`, `chore`.

**Scopes** name the area, not the file: `dns`, `config`, `update`, `watchdog`,
`cron`, `uninstall`, `setup`, `version`, `repair`.

Rules that matter more than the format:

- **One concern per commit.** If the body needs the word "also", it is probably
  two commits.
- **The body says what was broken**, not what you typed. A reader six months
  from now needs the failure, not the diff — the diff is already there.
- **Every commit builds green.** `sh test.sh` and shellcheck pass at each one,
  so `git bisect` works and any commit can be reverted alone.
- **Do not describe a fix you have not verified is in the diff.** This has
  happened here: a commit message claimed a change that a failed edit had
  silently dropped, and no test caught it.

## Before you push

```sh
sh test.sh                        # unit tests, GNU awk
AWK="busybox awk" sh test.sh      # the router runs BusyBox
find . -name "*.sh" -exec shellcheck -s sh -S warning -e SC2154,SC3043,SC2034 {} +
```

CI runs exactly these.

## Testing on hardware

The unit suite runs anywhere; iptables and firewall behavior is stubbed. Three
bugs in this repo's history were invisible to CI and only appeared on the
router — BusyBox awk mangling a regex, a cron guard matching another service's
job, and a config flag reset on re-install. **Anything touching iptables, cron,
`/etc/firewall.user` or boot persistence must be exercised on a real device,
including a reboot**, before it is called done.

On the router:

```sh
sh /tmp/controld/test.sh     # unit tests plus on-router integration tests
sh /cfg/status.sh            # per-bridge redirect coverage
```

## Style

POSIX `sh`, not bash — the router runs BusyBox ash. No process substitution,
no arrays, no `[[ ]]`. Prefer shell builtins over spawning `awk`/`sed` where it
is a wash, and when you do use `awk`, avoid passing regexes through `-v`.
