# proxmox-sensors

[![ci](https://github.com/ocristopfer/proxmox-sensors/actions/workflows/ci.yml/badge.svg)](https://github.com/ocristopfer/proxmox-sensors/actions/workflows/ci.yml)
[![release](https://img.shields.io/github/v/release/ocristopfer/proxmox-sensors)](https://github.com/ocristopfer/proxmox-sensors/releases/latest)
[![license](https://img.shields.io/github/license/ocristopfer/proxmox-sensors)](LICENSE)

CPU / GPU / NVMe / HDD temperatures in the Proxmox VE web UI:

- a **"Temperatures"** line in the node **Summary**, right below "CPU(s)";
- a **temperature history chart** next to the CPU / Network / RAM charts
  (hour, day, week, month and year views).

Targets Proxmox VE 7, 8 and 9 — the patchers refuse to touch files they don't recognise.

## Installation (recommended: .deb package)

On the Proxmox host, as root:

```bash
wget https://github.com/ocristopfer/proxmox-sensors/releases/latest/download/pve-sensors_all.deb
apt install ./pve-sensors_all.deb
```

The package pulls in its dependencies (`lm-sensors`, `librrds-perl`), loads
`drivetemp` (SATA temperatures), applies the patches and restarts the UI
services. Then reload the browser with **Ctrl+Shift+R**.

| Task | Command |
| --- | --- |
| Show the current state | `pve-sensors --status` |
| Preview the changes (diff only) | `pve-sensors --dry-run` |
| Text line only, no chart | `pve-sensors --no-graph` |
| Disable (until you run `pve-sensors` again) | `pve-sensors --revert` |
| Uninstall, keeping the history | `apt remove pve-sensors` |
| Uninstall and delete the history | `apt purge pve-sensors` |

**pve-manager upgrades:** every `apt upgrade` that updates `pve-manager`
overwrites the patched files. The package notices it (dpkg trigger) and
re-applies the patches on its own with the same options as last time.

To install without applying: `PVE_SENSORS_NO_APPLY=1 apt install ./pve-sensors_all.deb`.

## Without the package (over SSH)

From your machine, with root SSH access to the host:

```bash
./run.sh <PROXMOX-IP> --setup      # 1st time: installs lm-sensors/drivetemp and applies
./run.sh <PROXMOX-IP> --dry-run    # shows the diff, changes nothing
./run.sh <PROXMOX-IP>              # applies
./run.sh <PROXMOX-IP> --status     # current state
./run.sh <PROXMOX-IP> --revert     # undoes it (--purge also deletes the history)
```

On Windows PowerShell use `.\run.ps1` instead of `./run.sh`. The host can also
come from `PVE_HOST`; without a user it becomes `root@<host>`. `run.sh` streams
`src/` to a temporary directory on the host, runs it and removes it.

Directly on the host, as root, from a clone: `bash src/proxmox-enable-sensors.sh [options]`.
Without the package, re-run it after each `pve-manager` upgrade (the history is kept).

## How it works

| Piece | What it does |
| --- | --- |
| `Nodes.pm` patch | adds `thermalstate` (`sensors -j`) to `GET /nodes/{node}/status` and merges the temperature series into `GET /nodes/{node}/rrddata` |
| `pvemanagerlib.js` patch | "Temperatures" line + chart panel in the node Summary |
| `pve-sensors-collect` | systemd service that reads `sensors -j` every minute into `/var/lib/pve-sensors/sensors.rrd` |
| `PVE::SensorsRRD` | reads that RRD for the API merge |

PVE keeps node history in a fixed-schema RRD where no metric can be added, so
a parallel RRD is kept and merged into the API response; the front-end can't
tell the difference.

### Safety

1. **Backup** of both original files in `/root/pve-sensors-mod/<date-time>/`,
   with a standalone `RESTORE.sh`.
2. All patching happens on **temporary copies**; nothing in `/usr` is touched
   until validation passes.
3. **Proof of reversibility:** the patched copy is reverted and compared
   byte by byte with the original. Any difference aborts.
4. `perl -c` on the patched `Nodes.pm` before installing it.
5. **Atomic install** (write + rename), preserving owner and permissions.
6. **Health check** after restarting `pvedaemon`/`pveproxy`, plus API checks.
7. Any error or interruption after the backup triggers an **automatic rollback**.
8. Patches are pure insertions between markers; no original line is removed.
   If the PVE files changed in an unexpected way, the script refuses to patch.

## Project layout

```
src/
  proxmox-enable-sensors.sh      entry point: options and main flow
  lib/
    common.sh                    logging, temp dir, rollback, traps
    checks.sh                    pre-checks and dependencies
    series.sh                    detects the series this hardware has
    patch.sh                     patches copies, proves reversibility, dry-run
    install.sh                   backup, install/revert, restart, API checks, report
    status.sh                    --status
  patchers/                      Perl patchers for Nodes.pm and pvemanagerlib.js
  collector/                     pve-sensors-collect + its systemd unit
  perl/PVE/SensorsRRD.pm         RRD merge used by the API
  web/sensors-item.js            the "Temperatures" Summary item
packaging/                       .deb build (build-deb.sh, maintainer scripts)
tests/                           offline tests with stand-ins of the PVE files
run.sh, run.ps1                  run from your machine over SSH
```

## Development

```bash
make lint        # shellcheck
make test        # offline tests (run as root to include the --dry-run end-to-end test)
make deb         # builds dist/pve-sensors_<version>_all.deb
```

A release is published by pushing a tag: `git tag v1.2.3 && git push origin v1.2.3`.
The `release` workflow runs the tests, builds the `.deb` and attaches it to the
GitHub release.

## License

[MIT](LICENSE)
