# mikrotiksetup

Onboard a **LokalFi MikroTik** from the NUC terminal. Bash helpers live in **`scripts/`** in this repo. The **lokalfi-captive-portal** checkout is only for hotspot HTML, `deployment/docker/.env`, and `docker:bootstrap-mikrotik`.

Gold images are the **2026-09-17** backups here (July voucher set, not a blank router).

```bash
cd ~/Developer/tools/mikrotik-setup
npm link
mikrotiksetup
```

Enter runs **everything**. Other menu rows run one local script.

## Full setup

1. SSH: try `admin` / `lokalfi.net`, else sticker user/password (then set admin to `lokalfi.net`).
2. Enable hotspot **device-mode** only if it is not already `yes` (short reset tap otherwise).
3. Restore matching 09-17 gold (`E50UG` or `RB750Gr3` only). `setup --skip-restore` continues without loading gold.
4. Wait for reboot at **192.168.10.1** on **ether2-LAN**.
5. RB750: WAN parity, format the **mounted** SD as exFAT on the router, upload hotspot there, set `hsprof1` html-directory. Empty `sd1`/`sd2`/`usb1` slot names are ignored. If more than one card is mounted, the tool asks which slot and continues.
6. E50UG: upload to `flash/hotspot` (never format a disk).
7. Apply portal garden/DNS using this NUC’s LAN IP.
8. `npm run docker:bootstrap-mikrotik` if the portal app container is running.

## Factory vs 10.1

A shop-fresh box is often **192.168.88.1**. Typing that IP does nothing if the NUC is only **192.168.10.220**. Plug into the factory LAN, or add `192.168.88.x` on the NUC yourself. After restore, use ether2 and `192.168.10.1`.

## SD cards (RB750)

- Count **mounted filesystems** only, not empty RouterBOARD slots.
- No mounted card: insert one and press Enter to retry (or skip and finish garden/bootstrap).
- Format is `/disk format … file-system=exfat` on the **router**, not `mkfs` on the NUC.

## Lab box

Serial **HJC0A5MY028** is refused unless `mikrotiksetup restore --force` / `mikrotiksetup setup --force`.

## Config

`~/.config/mikrotiksetup/config.json` — path to **lokalfi-captive-portal**. `mikrotiksetup config` to set it.

## Commands

| Command | Local script |
|---------|----------------|
| `mikrotiksetup setup` | full flow |
| `mikrotiksetup upload-hotspot` | `scripts/upload-hotspot-to-mikrotik.sh` |
| `mikrotiksetup wan` | `scripts/mikrotik-router-parity-fix.sh` |
| `mikrotiksetup device-mode` | `scripts/mikrotik-enable-hotspot-device-mode.sh` |
| `mikrotiksetup apply-portal-network` | `scripts/mikrotik-apply-portal-network.sh` |
| `mikrotiksetup pull-backup` | `scripts/mikrotik-pull-backup.sh` |
| `mikrotiksetup restore` | `scripts/mikrotik-restore-backup.sh` |
| `mikrotiksetup format-sd` | `scripts/mikrotik-format-sd.sh` |
| `mikrotiksetup bootstrap` | portal `docker:bootstrap-mikrotik` |

## Repository

<https://github.com/reiinnprojects/mikrotik-setup>
