# VPSChecker

[Русская версия](README_RU.md)

VPSChecker is a small terminal utility designed to assess whether a VPS IP is
suitable for use as a VPN exit node. It checks three independent areas:

- IP reputation and trust signals;
- reachability from a selected country (Russia by default);
- local and external availability of VLESS TCP and Hysteria2 UDP ports.

Reputation, regional reachability, and service state are reported separately.
The utility is intended to leave minimal changes on the VPS and uses pinned,
checksum-verified versions of third-party tools.

IP reputation data is collected with a pinned `xykt/IPQuality` version in IPv4
JSON/privacy mode. Its dependency installer is disabled, and successful raw JSON
is kept unchanged. VPSChecker separately derives an `OK`, `WARNING`, `POOR`, or
`UNKNOWN` VPN trust assessment with concrete reasons. Hosting classification and
mail reputation do not affect this assessment.

Regional checks use the current Check-Host node list. VPSChecker selects up to
three nodes in the target country and three control nodes in other countries,
then runs an auxiliary ping, a VLESS TCP connection check, and a Hysteria2 UDP
check. A UDP result is reported as `OPEN_OR_FILTERED`, not as proof that
Hysteria2 works.

If required APT packages are missing, VPSChecker lists them and asks for
confirmation before running `apt-get update` and installing only those packages
without recommendations. It never runs a system upgrade or `autoremove`.

By default, packages added by VPSChecker are kept and recorded in
`.vpschecker-cleanup.plan` in the current directory. The terminal prints a command
that can remove the accumulated packages later. Pass `--cleanup` to remove them
automatically at exit. Existing packages and any versions updated during
installation are always kept.

Both cleanup modes first run an APT simulation and continue only when no package
outside the recorded set would be affected. They never use `autoremove`.

## Temporary files

Runtime files are created under `${TMPDIR}` or `/tmp` when `TMPDIR` is unset.
IPQuality source and runtime copies, raw JSON, diagnostics, the VPN trust result,
and Check-Host responses are stored in a `vpschecker.XXXXXX` directory. APT
change tracking uses a separate `vpschecker-deps.XXXXXX` directory. Both are
removed on normal exit and handled termination signals.

`.vpschecker-cleanup.plan` is not a temporary runtime file. It remains until the
recorded packages are removed successfully.

## Reports

Each successful run creates two private (`0600`) files in the current directory:

- `vpschecker-report-<UTC timestamp>-<PID>.json`;
- `vpschecker-report-<UTC timestamp>-<PID>.txt`.

The JSON report has stable top-level sections for reputation, VPN suitability,
replacement advice, regional reachability, ports, protocol checks, and cleanup.
It also embeds the unchanged raw IPQuality result. Replacement advice is reported
as `REPLACEMENT_JUSTIFIED`, `REPLACEMENT_MAY_HELP`, `REPLACEMENT_UNLIKELY`, or
`INCONCLUSIVE`, with supporting reasons and facts. Final reports are preserved;
only temporary runtime files are removed on exit. The cleanup section records
whether added packages were deferred, removed, not required, skipped as unsafe,
or could not be removed.

## Requirements

- Debian or Ubuntu;
- Bash 5.1 or newer;
- IPv4 connectivity.

## Usage

Run with automatic external IPv4 detection and the default ports:

```bash
./vps-check.sh
```

The default target country is Russia (`ru`), using a two-letter ISO country code.
The default ports are TCP/443 for VLESS and UDP/443 for Hysteria2. The country,
IP, and either port can be specified explicitly:

```bash
./vps-check.sh \
  --ip 203.0.113.10 \
  --country de \
  --vless-port 2053 \
  --hysteria2-port 8443
```

Show command help:

```bash
./vps-check.sh --help
```

Also print the text report to the terminal while keeping both report files:

```bash
./vps-check.sh --print-report
```

Automatically execute the pending cleanup plan after the checks:

```bash
./vps-check.sh --cleanup
```

Without that flag, run the printed command later from the same directory:

```bash
./vps-check.sh cleanup
```

The standalone command shows the exact packages and asks for confirmation.

List the country codes currently available through Check-Host:

```bash
./scripts/list-check-host-locations.sh
```

The list includes the current node count and cities for each country.

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
bash tests/reputation_test.sh
bash tests/check_host_test.sh
bash tests/list_check_host_locations_test.sh
bash tests/report_test.sh
bash tests/cleanup_test.sh
bash tests/update_ipquality_test.sh
```
