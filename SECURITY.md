# Security policy

`pve-sensors` runs **as root on the Proxmox host**: it patches `Nodes.pm` and
`pvemanagerlib.js`, restarts `pvedaemon`/`pveproxy` and installs a systemd
service. Please treat security issues accordingly.

## Reporting a vulnerability

Do **not** open a public issue. Use GitHub's private vulnerability reporting
(the "Report a vulnerability" button on the repository's **Security** tab) and include:

- what is affected (API patch, web UI patch, collector, `.deb` maintainer scripts,
  `run.sh`/`run.ps1`);
- steps to reproduce, or a proof of concept;
- the version (`dpkg -s pve-sensors | grep Version`, or the commit if you run from
  a clone) and the Proxmox VE / `pve-manager` version.

You should get an answer within a few days. Fixes are released as a new tagged
version; the advisory is published once a fixed release is available.

## Supported versions

Only the latest release receives fixes.

## Scope

In scope: anything this repository adds to the host — for example the
`thermalstate`/`rrddata` additions to the API leaking data to a user without
`Sys.Audit` on the node, script injection through sensor labels in the Summary
item, unsafe temporary files, or a failed patch leaving the host in a broken state.

Out of scope: bugs in Proxmox VE, `lm-sensors` or kernel drivers themselves —
please report those upstream.

## Hardening notes

- Download the `.deb` only from this repository's GitHub releases.
- `run.sh`/`run.ps1` need root SSH to the host; prefer key-based authentication.
- `pve-sensors --dry-run` shows the exact diff before anything is changed, and
  every run keeps a backup with a standalone `RESTORE.sh` in `/root/pve-sensors-mod/`.
