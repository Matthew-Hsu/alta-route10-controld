# Contributing

## Commit messages

This project follows [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/):

```
type(scope): subject

body explaining what was wrong and why this is the fix

Co-Authored-By: ...
```

**Types used here:** `fix`, `feat`, `refactor`, `docs`, `test`, `ci`, `chore`.

**AI-assisted contributions are welcome and disclosed.** This project is
maintained with the help of AI coding assistants, including Claude Code.
That's how a one-person, spare-time fork keeps up with fixes across BusyBox
quirks, VLAN edge cases, and hardware verification. Commits and PRs may carry
a `Co-Authored-By` trailer, a session link, or similar tool attribution.
Leave it.

What isn't negotiable: nothing merges on an assistant's say-so alone. Every
change here is read line-by-line by a human, edited where it's wrong, and run
through `test.sh`. Anything touching iptables, cron, firewall rules, or boot
persistence is also tested on real hardware (see "Testing on hardware"
below). Disclosure alone doesn't replace that review.

See [AGENTS.md](AGENTS.md) for operational notes aimed specifically at an AI
agent picking up work in this repo.

**Scopes** name the area, not the file: `dns`, `config`, `update`, `watchdog`,
`cron`, `uninstall`, `setup`, `version`, `repair`.

Rules that matter more than the format:

- **One concern per commit.** If the body needs the word "also", it is probably
  two commits.
- **The body says what was broken**, not what you typed. A reader six months
  from now needs the failure, not the diff. The diff is already there.
- **Every commit builds green.** `sh test.sh` and shellcheck pass at each one,
  so `git bisect` works and any commit can be reverted alone.
- **Do not describe a fix you have not verified is in the diff.** This has
  happened here: a commit message claimed a change that a failed edit had
  silently dropped, and no test caught it.
- **Assert on outcomes, not on the shape of the code.** A test that greps the
  source for your own implementation will pass while the behaviour is broken.
  That happened here too, asserting a `uci delete` appeared twice while the
  value it was meant to clear survived on the router. Source-grep assertions
  are only a regression guard for behaviour that cannot run off-device, never
  evidence that something works.
- **Trace the whole sequence, not the function.** The same bug took three
  attempts because the fix was correct in isolation and undone by a service
  restart later in the caller. Grep for every restart, every write to the same
  key, before concluding.

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
router: BusyBox awk mangling a regex, a cron guard matching another service's
job, and a config flag reset on re-install. **Anything touching iptables, cron,
`/etc/firewall.user` or boot persistence must be exercised on a real device,
including a reboot**, before it is called done.

On the router:

```sh
sh /tmp/controld/test.sh     # unit tests plus on-router integration tests
sh /cfg/status.sh            # per-bridge redirect coverage
```

## Style

POSIX `sh`, not bash. The router runs BusyBox ash. No process substitution,
no arrays, no `[[ ]]`. Prefer shell builtins over spawning `awk`/`sed` where it
is a wash, and when you do use `awk`, avoid passing regexes through `-v`.
