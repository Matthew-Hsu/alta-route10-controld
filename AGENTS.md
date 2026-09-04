# Agent Notes

Operational notes for an AI coding agent picking up work in this repository.
Read [`README.md`](README.md) and [`CONTRIBUTING.md`](CONTRIBUTING.md) first.
This file doesn't repeat what's there, only what's specific to working here
as an agent rather than a human.

## Your sandbox is not the target

This code runs on an Alta Labs Route 10 router: `aarch64`, BusyBox `ash`,
BusyBox `awk`, an OpenWrt-derived filesystem, `iptables`, `uci`, and a
persistent `/cfg` partition that survives firmware updates. Your execution
environment almost certainly has none of that.

- `sh test.sh` here runs the *unit* suite; iptables and firewall calls are
  stubbed. A green run proves the logic, not the on-router behavior.
- Anything touching iptables, cron, `/etc/firewall.user`, or boot persistence
  (`rc.local`, `post-cfg.sh`) cannot be verified from a sandbox. Say so
  explicitly in your PR description instead of claiming it's tested.
- The generated `watchdog.sh` is the exception: the suite extracts it from
  `setup.sh`, redirects its `/cfg` and `/tmp` paths into a sandbox and runs it
  against stubs, so its control flow *can* be tested off-device. What it does
  to iptables still cannot. Three
  real bugs in this project's history were invisible to CI and only surfaced
  on hardware (see `CONTRIBUTING.md`'s "Testing on hardware").
- Run the suite under both awks before proposing a change:
  `sh test.sh` and `AWK="busybox awk" sh test.sh`. They disagree often enough
  that this has caught real regressions that a GNU-awk-only run missed.

## Verify before you claim

Don't describe a fix as done until you've re-read the diff and confirmed the
change is actually there. This has gone wrong before: a commit message once
claimed a fix that a failed edit had silently dropped, and nothing caught it
because the accompanying test checked the shape of the code (grepping for
the intended change) rather than its outcome. If you can't run the real
behavior, say plainly what you verified and what you couldn't.

## Attribution

Commits and PRs you make here may carry your tool's `Co-Authored-By` trailer.
This project welcomes that disclosure, see `CONTRIBUTING.md`. Don't strip it,
and don't apply a stricter attribution policy of your own that contradicts
what's written there.

**But never put a URL in a commit message or PR body**, including a session
link your harness adds automatically. Many harnesses append one; remove it.
This is not optional and it is not a matter of taste — see `CONTRIBUTING.md`
for why. Cite commits by hash and files by path instead.

## Scope discipline

One concern per commit, per `CONTRIBUTING.md`. If you're operating
semi-autonomously, resist folding an unrelated cleanup into the same commit
just because you noticed it while you were already in the file.
