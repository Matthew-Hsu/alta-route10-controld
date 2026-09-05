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
a `Co-Authored-By` trailer or similar tool attribution. Leave it.

**No URLs in commit messages or PR bodies.** Not session links, not tool
homepages, not anything else. A commit message is read in `git log` on a
router over SSH, years after the link stops resolving, by someone who cannot
click it — attribution is a name, not a link. If your tool appends one by
default, strip it before committing. Reference commits by hash and files by
path; both stay meaningful offline and forever.

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

The unit suite runs anywhere; iptables and firewall behavior is stubbed. Every
bug in this repo's history that CI could not see appeared on the router first:
BusyBox awk mangling a regex, a cron guard matching another service's job, a
config flag reset on re-install, `logread` failing on firmware whose syslogd
has no buffer, and a wait loop that was fast in a sandbox and pathological on
hardware. **Anything touching iptables, cron, `/etc/firewall.user` or boot
persistence must be exercised on a real device, including a reboot**, before it
is called done.

**Time is one of the things a sandbox gets wrong.** A loop bounded by iteration
count rather than wall clock is only as fast as its slowest probe, and probe
costs differ by an order of magnitude between CI and a router: a DNS query to a
closed local port returns instantly in a container and costs the resolver's
full timeout on a Route 10. That turned a "15 second" wait into 90 seconds, put
the watchdog's recovery cycle over its own cron interval, and let instances
overlap and corrupt each other's state, none of it visible in a green suite.
Bound waits by time, and assert on elapsed time rather than on iterations.

**README.md's "Verification Status" section is the canonical list of what has
and has not been proven on a device.** It is written for users deciding how much
to trust a feature, and it is the first thing to update when you verify one:
move the row out of the table, and say in the commit what you ran. A claim there
must be something you watched happen on hardware, not something the suite
covers. Do not add a row for work you merely intend to do; the list is only
useful if every entry is load-bearing.

On the router:

```sh
sh /tmp/controld/test.sh     # unit tests plus on-router integration tests
sh /cfg/status.sh            # per-bridge redirect coverage
```

## Releases

`VERSION` in `lib.sh` is the version of these scripts. **Only a release commit
on `master` moves it, and that commit is tagged.** A branch never bumps it, no
matter how much it changes.

Two reasons. Unmerged work is not released, so a branch that raises `VERSION`
is claiming a version that does not exist yet — and if it is never merged, or
merged after something else that did the same, the number is simply wrong. And
two branches that both bump collide on the one line guaranteed to conflict.

So: land the work with `VERSION` untouched. When you decide to cut a release,
one commit on `master` sets the number and one tag records it:

```sh
git tag -a v1.6.0 -m "..."      # the tag is what makes it a release
```

Pick the number from what accumulated since the last tag, using the scheme in
`lib.sh`: MAJOR for a change an existing install cannot upgrade into, MINOR for
new capability that upgrades cleanly, PATCH for fixes that add no behaviour.

`CTRLD_PIN` is not a release number and moves independently, whenever you
deliberately adopt a newer upstream `ctrld`.

## Style

POSIX `sh`, not bash. The router runs BusyBox ash. No process substitution,
no arrays, no `[[ ]]`. Prefer shell builtins over spawning `awk`/`sed` where it
is a wash, and when you do use `awk`, avoid passing regexes through `-v`.
