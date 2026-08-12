# VPSChecker

[Русская версия](README_RU.md)

VPSChecker is a small terminal utility designed to assess whether a VPS IP is
suitable for use as a VPN exit node. It checks three independent areas:

- IP reputation and trust signals;
- reachability from Russia;
- local and external availability of VLESS TCP and Hysteria2 UDP ports.

Reputation, regional reachability, and service state are reported separately.
The utility is intended to leave minimal changes on the VPS and uses pinned,
checksum-verified versions of third-party tools.

IP reputation data is collected with a pinned `xykt/IPQuality` version in IPv4
JSON/privacy mode. Its dependency installer is disabled, and successful raw JSON
is kept unchanged for report generation.

If required APT packages are missing, VPSChecker lists them and asks for
confirmation before running `apt-get update` and installing only those packages
without recommendations. It never runs a system upgrade or `autoremove`.

## Requirements

- Debian or Ubuntu;
- Bash 5.1 or newer;
- IPv4 connectivity.

## Usage

Run with automatic external IPv4 detection and the default ports:

```bash
./vps-check.sh
```

The default ports are TCP/443 for VLESS and UDP/443 for Hysteria2. The IP and
either port can be specified explicitly:

```bash
./vps-check.sh \
  --ip 203.0.113.10 \
  --vless-port 2053 \
  --hysteria2-port 8443
```

Show command help:

```bash
./vps-check.sh --help
```

## Updating IPQuality

Review the latest upstream change and update the pinned version:

```bash
./scripts/update-ipquality.sh
```

A full commit SHA can be reviewed instead:

```bash
./scripts/update-ipquality.sh COMMIT_SHA
```

The script verifies the current source, downloads the candidate, shows its
checksum and diff, and asks for confirmation before changing the pin.

## Tests

```bash
bash tests/cli_test.sh
bash tests/preflight_test.sh
bash tests/dependencies_test.sh
bash tests/ipquality_download_test.sh
bash tests/ipquality_run_test.sh
bash tests/update_ipquality_test.sh
```
