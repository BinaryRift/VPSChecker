# VPSChecker

[Русская версия](README_RU.md)

VPSChecker is a terminal utility for assessing whether a VPS IP is suitable for
use as a VPN exit node. It checks IP reputation, reachability from a selected
country, and the local and external availability of VLESS TCP and Hysteria2 UDP
ports. The default target country is Russia.

Each successful run produces text and JSON reports with separate check results,
an overall VPN suitability assessment, and advice on whether requesting an IP
replacement from the hosting provider is justified. The checks are designed to
leave minimal changes on the VPS.

## Requirements

- Debian or Ubuntu;
- Bash 5.1 or newer;
- `curl` to download the installer;
- IPv4 connectivity.

## Quick start

Run these commands from the directory where you want to keep the reports.
Download the installer, install the latest checksum-verified release, and remove
the installer after a successful installation:

```bash
# Download the installer.
curl -fsSLo install-vpschecker.sh \
  https://raw.githubusercontent.com/BinaryRift/VPSChecker/main/install.sh &&

# Install the latest release.
bash install-vpschecker.sh &&

# Remove the installer.
rm -- install-vpschecker.sh
```

Run the check with automatic external IPv4 detection, Russia as the target
country, and TCP/443 and UDP/443 as the VLESS and Hysteria2 ports:

```bash
# Run the check with default settings.
./vpschecker/vps-check.sh
```

If VPSChecker prints a cleanup command, run it later from the same directory. It
shows the exact packages and asks for confirmation before removing them:

```bash
# Remove only APT packages added by VPSChecker.
./vpschecker/vps-check.sh cleanup
```

After cleanup, or when no cleanup was required, remove the utility. Reports under
`./reports` are outside its directory and remain available:

```bash
# Remove VPSChecker while keeping its reports.
rm -r -- ./vpschecker
```

## Advanced usage

The target country uses a two-letter ISO country code. The IP, country, default
ports, and report directory can be specified explicitly:

```bash
./vpschecker/vps-check.sh \
  --ip 203.0.113.10 \
  --country de \
  --vless-port 2053 \
  --hysteria2-port 8443 \
  --report-dir reports/de
```

When `--ip` is omitted, VPSChecker detects the external IPv4 through HTTPS. An
explicit value skips that request.

Also print the full text report while keeping both report files:

```bash
./vpschecker/vps-check.sh --print-report
```

Status colors are used only for interactive terminal output. Saved reports and
`--print-report` remain plain text. To disable colors elsewhere, set `NO_COLOR`
to any value:

```bash
NO_COLOR=1 ./vpschecker/vps-check.sh
```

Automatically remove packages added by VPSChecker after the checks:

```bash
./vpschecker/vps-check.sh --cleanup
```

List the country codes currently available through Check-Host:

```bash
./vpschecker/vps-check.sh list-locations
```

The list includes the current node count and cities for each country.

Show command help or the installed version:

```bash
./vpschecker/vps-check.sh --help
./vpschecker/vps-check.sh --version
```

## Reports

Each successful run creates two private (`0600`) files under `./reports`, relative
to the current directory:

- `reports/vpschecker-report-<UTC timestamp>-<PID>.json`;
- `reports/vpschecker-report-<UTC timestamp>-<PID>.txt`.

The directory is created only when the reports are ready to be generated. Set a
different relative or absolute path with `--report-dir`; an existing directory's
permissions are not changed:

```bash
./vpschecker/vps-check.sh --report-dir /var/lib/vpschecker/reports
```

The JSON report has stable top-level sections for reputation, VPN suitability,
replacement advice, regional reachability, ports, protocol checks, and cleanup.
It also embeds the unchanged raw IPQuality result. Replacement advice is reported
as `REPLACEMENT_JUSTIFIED`, `REPLACEMENT_MAY_HELP`, `REPLACEMENT_UNLIKELY`, or
`INCONCLUSIVE`, with supporting reasons and facts. Final reports are preserved;
only temporary runtime files are removed on exit. The cleanup section records
whether added packages were deferred, removed, not required, skipped as unsafe,
or could not be removed.

## Temporary files

Runtime files are created under `${TMPDIR}` or `/tmp` when `TMPDIR` is unset.
IPQuality source and runtime copies, raw JSON, diagnostics, the VPN trust result,
and Check-Host responses are stored in a `vpschecker.XXXXXX` directory. APT
change tracking uses a separate `vpschecker-deps.XXXXXX` directory. Both are
removed on normal exit and handled termination signals.

`.vpschecker-cleanup.plan` is not a temporary runtime file. It remains until the
recorded packages are removed successfully.

## Versioning

`VERSION` is the single source of the tool version. VPSChecker uses semantic
versions, exposes the value through `--version`, and includes it in text and JSON
reports. Releases should use a matching `v<version>` Git tag, for example
`v0.1.0`, and may then be published as a GitHub Release.

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

## External services

VPSChecker automatically uses:

- [xykt/IPQuality](https://github.com/xykt/IPQuality) — downloaded at a pinned
  commit and run to collect IP reputation and geolocation signals. IPQuality
  contacts its own upstream data providers; privacy mode prevents publishing its
  online report link, but does not make the check offline.
- [Check-Host API](https://check-host.net/about/api?lang=en) — provides the
  current node list and performs regional ping, TCP, and UDP checks.
- [ipify](https://www.ipify.org/) — detects the external IPv4 through
  `https://api.ipify.org` only when `--ip` is omitted.

For `WARNING` and `POOR` results, reports include links for manual verification
with [AbuseIPDB](https://www.abuseipdb.com/),
[Scamalytics](https://www.scamalytics.com/),
[IPQualityScore](https://www.ipqualityscore.com/free-ip-lookup-proxy-vpn-test/),
[VirusTotal](https://www.virustotal.com/gui/home/search), and
[Cisco Talos Reputation Center](https://talosintelligence.com/reputation_center/).
VPSChecker does not query these pages merely to generate the links. Some of them
may also be upstream data sources used internally by IPQuality.

## How checks work

Reputation, regional reachability, and service state are evaluated and reported
separately. IP reputation data is collected with a pinned, checksum-verified
`xykt/IPQuality` version in IPv4 JSON/privacy mode. Its dependency installer is
disabled, and successful raw JSON is kept unchanged. VPSChecker derives an `OK`,
`WARNING`, `POOR`, or `UNKNOWN` VPN trust assessment with concrete reasons.
Hosting classification and mail reputation do not affect this assessment.

Regional checks use the current Check-Host node list. VPSChecker selects up to
three nodes in the target country and three control nodes in other countries,
then runs an auxiliary ping, a VLESS TCP connection check, and a Hysteria2 UDP
check. A UDP result is reported as `OPEN_OR_FILTERED`, not as proof that
Hysteria2 works.

The read-only preflight determines the operating system, current privileges,
external IPv4, required commands and APT packages, and local TCP/UDP listeners.
It does not install packages or invoke `sudo`.

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

## License

VPSChecker is licensed under the [MIT License](LICENSE). Third-party software
keeps its own license; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
