# mikrotiksetup

Onboard a **LokalFi MikroTik** from the NUC terminal. Wraps scripts in **lokalfi-captive-portal**. Gold images are the **2026-09-17** backups in this repo (July voucher set, not a blank router).

```bash
cd ~/Developer/tools/mikrotik-setup
npm link
mikrotiksetup
```

Enter runs **everything**. Other menu rows run one portal script.

## Full setup

1. SSH: try `admin` / `lokalfi.net`, else sticker user/password (then set admin to `lokalfi.net`).
2. Enable hotspot **device-mode** (short reset tap or power-cycle on the router).
3. Restore matching 09-17 gold (`E50UG` or `RB750Gr3` only).
4. Wait for reboot at **192.168.10.1** on **ether2-LAN**.
5. RB750: WAN parity, format the **one** SD as exFAT on the router, upload hotspot there, set `hsprof1` html-directory.
6. E50UG: upload to `flash/hotspot` (never format a disk).
7. Apply portal garden/DNS using this NUC’s LAN IP.
8. `npm run docker:bootstrap-mikrotik` if the portal app container is running.

## Factory vs 10.1

A shop-fresh box is often **192.168.88.1**. Typing that IP does nothing if the NUC is only **192.168.10.220**. Plug into the factory LAN, or add `192.168.88.x` on the NUC yourself. After restore, use ether2 and `192.168.10.1`.

## SD cards (RB750)

- No card: the tool stops and tells you to insert one.
- Two or more volumes: it stops. Do not guess (USB vs SD).
- Format is `/disk format … file-system=exfat` on the **router**, not `mkfs` on the NUC.

## Lab box

Serial **HJC0A5MY028** is refused unless `mikrotiksetup restore --force` / `mikrotiksetup setup --force`.

## Config

`~/.config/mikrotiksetup/config.json` — path to **lokalfi-captive-portal**. `mikrotiksetup config` to set it.

## Commands

| Command | Portal script |
|---------|----------------|
| `mikrotiksetup setup` | full flow |
| `mikrotiksetup upload-hotspot` | `mikrotik:upload-hotspot` |
| `mikrotiksetup wan` | `mikrotik:router-parity-fix` |
| `mikrotiksetup device-mode` | `mikrotik:enable-hotspot-device-mode` |
| `mikrotiksetup apply-portal-network` | `mikrotik:apply-portal-network` |
| `mikrotiksetup pull-backup` | `mikrotik:pull-backup` |
| `mikrotiksetup restore` | `mikrotik:restore-backup` |
| `mikrotiksetup format-sd` | `mikrotik:format-sd` |
| `mikrotiksetup bootstrap` | `docker:bootstrap-mikrotik` |

Bash helpers stay in the portal repo until this CLI is proven on hardware.

## Repository

<https://github.com/reiinnprojects/mikrotik-setup>

