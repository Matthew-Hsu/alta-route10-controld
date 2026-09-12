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
  to iptables still cannot, and neither is how long anything takes: probe costs
  differ by an order of magnitude between a container and a router, which is how
  a wait loop bounded by iterations passed CI and ran six times too slow on
  hardware. Every bug in this project's history that CI could not see surfaced
  on hardware first (see `CONTRIBUTING.md`'s "Testing on hardware").
- Run the suite under both awks before proposing a change:
  `sh test.sh` and `AWK="busybox awk" sh test.sh`. They disagree often enough
  that this has caught real regressions that a GNU-awk-only run missed.

- Before saying a feature works, check README.md's "Verification Status"
  section. If it is in the "not exercised on hardware" table, say so rather
  than implying the suite covers it. If you do verify one on a device, move
  the row and record what you ran.

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
This is a hard rule. See `CONTRIBUTING.md` for why. Cite commits by hash and
files by path instead.

## Prose

Before writing or editing prose here, read `blader/humanizer`'s `SKILL.md` and
apply it. Fetch it at the time you need it rather than copying it into this
repo, so its updates reach you without anyone maintaining a snapshot.

Prose means markdown, commit messages, PR bodies, and shell comments. Anything
written for a person to read is held to the same standard wherever it lives.

**A comment or string that code reads is an interface, not prose. Never reword
one.** They are listed by what they say rather than where they sit, because
line numbers drift and a stale pointer aims attention at the wrong line:

- the comment carrying `controld-boot-hook`, in the `rc.local` heredoc in
  `setup.sh`. `is_our_rc_local()` greps the installed hook for it, and
  `uninstall.sh` decides from that whether the hook is ours to remove
- the `test.sh` fixture that mirrors that line, which only tests the real
  thing while the two match
- the `── Inline benchmark ──` header in `setup.sh`, which `test.sh` uses as a
  `sed` range anchor from another file
- every `# shellcheck` directive, including the trailing prose ones. The prose
  after the directive is editable; the directive is not
- every shebang, the four inside `setup.sh`'s heredocs included
- user-facing message strings a test anchors on by text, such as
  `uninstall.sh`'s "carries no redirect to port". These are UI, not commentary

Every one of those is guarded, so the suite catches a breakage whether or not
anyone read this section. Each guard was confirmed by mutating the thing it
protects and watching it fail. The shebangs and the `shellcheck disable`
directives needed guards built for them: removing a generated script's shebang
passed all 501 assertions, and deleting a directive left shellcheck green,
because the main lint runs at `-S warning` and SC2086 is info-level. CI now
makes a second, narrow pass for that one code.

When you add an interface, add its guard in the same commit, and prove the
guard works by breaking the thing it protects and watching it fail. You have
added one whenever code starts reading text that reads like commentary or like
a message: a new marker grepped out of a file, a new section header used as a
range anchor, a new printed line a test keys on. Add it to the list above too,
so a person knows without reading the assertion.

A guard firing on a change you meant to make is the guard working. Update it
and say in the commit what moved. Deleting one to get green is how this project
ends up back where it started, with a documented rule and nothing enforcing it.

That rule is the only thing covering an interface added later, so treat it as
load-bearing. The guards above protect these six and nothing else: add a
seventh without one and the suite stays green, both when you add it and when
someone reworks the comment away months later, in a different change, with
nothing to connect the breakage back to the edit that caused it. Simulating
exactly that is how this section was checked. Whether a new interface is
guarded is a decision someone makes, not something the tooling notices.

Two limits on how to do the work. Never sweep the tree: one file per commit,
because a 300-line prose diff cannot be read line by line, and this project
says every diff is. And prove that only comments moved, rather than promising
it: run `code_only()` over the file before and after and diff the two. Matching
output means no code line changed. A trailing inline comment survives that
filter, so check those by eye.

Title-case headings stay as they are. They are the convention across the repo
and `README.md`'s table of contents links to them.

If you cannot reach the skill, the one rule worth keeping from it: do not use
an em dash as a general-purpose connector. Use the punctuation the sentence is
already asking for.

## Scope discipline

One concern per commit, per `CONTRIBUTING.md`. If you're operating
semi-autonomously, resist folding an unrelated cleanup into the same commit
just because you noticed it while you were already in the file.
