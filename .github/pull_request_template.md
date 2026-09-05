<!--
Title: type(scope): subject — Conventional Commits, per CONTRIBUTING.md.
Types used here: fix, feat, refactor, docs, test, ci, chore.
Scopes name the area, not the file: dns, config, update, watchdog, cron,
uninstall, setup, version, repair.
-->

## What was broken or missing

<!-- Say what was wrong, not what you changed — the diff already shows the
     change. A commit message here is a good draft: "X did Y when Z, because
     ..." -->

## Hardware

<!-- CI already runs `sh test.sh` under both awks and shellcheck on every PR
     automatically — that result is on this page below, no need to repeat it
     here. What CI cannot see is this section: iptables, cron,
     /etc/firewall.user, and boot persistence (rc.local, post-cfg.sh) can only
     be proven on a real Route 10, including a reboot. See AGENTS.md's "Your
     sandbox is not the target." -->

- [ ] Not applicable — this doesn't touch iptables, cron, firewall.user, or
      boot persistence
- [ ] Exercised on a real Route 10, including a reboot — what you ran:
- [ ] Not yet exercised on hardware — said so explicitly above rather than
      implying `test.sh` covers it, and updated README's Verification Status
      table if this changes what's proven vs. not

## Scope and commits

- [ ] One concern. If the summary above needs the word "also," this is
      probably two PRs
- [ ] Every commit builds green and says what was broken, not just what
      changed
- [ ] No URLs anywhere in this PR — not in the description, not in any commit
      message, not a session link a tool appended automatically. Cite commits
      by hash and files by path instead; see CONTRIBUTING.md for why

## AI-assisted contributions

This project welcomes these — see CONTRIBUTING.md.

- [ ] Not applicable
- [ ] Commits carry a `Co-Authored-By` trailer disclosing the tool
- [ ] A human read the diff line-by-line before this was opened, not just the
      tool's summary of it
