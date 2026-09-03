# Security Policy

This project changes DNS routing and firewall rules on a home router. If you
find a way to bypass, disable, or spoof that behavior, or any other security
issue in these scripts, please report it privately rather than opening a
public issue.

## Reporting a Vulnerability

Use GitHub's private vulnerability reporting for this repository: go to the
**Security** tab, then **Report a vulnerability**. This opens a draft security
advisory visible only to the maintainer, so the issue isn't public before a
fix is out.

If that option isn't available to you (for example, it hasn't been enabled
yet), open a regular issue asking for a private channel and it will be set up.

## Scope

In scope: `setup.sh`, `reconfigure.sh`, `uninstall.sh`, `lib.sh`, `watchdog.sh`,
`post-cfg.sh`, and the iptables/uci/cron behavior they configure.

Out of scope: the `ctrld` binary itself and ControlD's service. Report those
upstream to [Control-D-Inc/ctrld](https://github.com/Control-D-Inc/ctrld) or
[ControlD](https://controld.com).

## Response

This is a personal project maintained in spare time. There's no SLA, but
reports will get a response, and a fix will be prioritized over new features.
