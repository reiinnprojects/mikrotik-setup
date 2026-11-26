# mikrotiksetup

Set up a LokalFi MikroTik from a terminal. Bash helpers live in `scripts/`. The lokalfi-captive-portal checkout supplies hotspot HTML, `deployment/docker/.env`, and `docker:bootstrap-mikrotik`.

The 17 Sep 2026 backups in this repo are the July voucher set, not a blank router.

```bash
cd ~/Developer/tools/mikrotik-setup
npm link
mikrotiksetup
```

Enter runs full setup. Other menu rows run one local script.

## Full setup

1. SSH: try `admin` / `lokalfi.net`, else sticker user/password (then set admin to `lokalfi.net`).
2. Enable hotspot device-mode only if it is not already `yes` (short reset tap otherwise).
3. Restore the matching 17 Sep backup (`E50UG` or `RB750Gr3` only). `setup --skip-restore` continues without loading that backup.
4. Wait for reboot at **192.168.10.1** on **ether2-LAN**.
5. RB750: fix WAN, format the mounted SD as exFAT on the router, upload hotspot there, set `hsprof1` html-directory. Empty `sd1`/`sd2`/`usb1` slot names are ignored. If more than one card is mounted, the tool asks which slot and continues. No card, or format failure: upload to internal `flash/hotspot`.
6. E50UG: upload to `flash/hotspot` (never format a disk).
7. Point the hotspot at the app LAN IP (DNS, walled garden, DHCP option 114, port-443 client-IP NAT). This step sets `hsprof1` `dns-name` and `hotspot-address`, then bounces `hotspot1`.
8. `npm run docker:bootstrap-mikrotik` if the portal app container is running.

## Update a live site

`mikrotiksetup update` is for a router people are already using. It does not restore the 17 Sep backup, format a disk, change WAN, or rewrite hotspot users, user profiles, or `hsprof1`.

1. Read `hsprof1` `html-directory`. If it is empty, or it is not `flash/hotspot` or `<volume>/flash/hotspot`, stop.
2. Upload the current portal files into that folder. Leave `html-directory` as it is.
3. Apply DNS, walled garden, DHCP option 114, and the port-443 NAT accept. Leave `dns-name`, `hotspot-address`, and `hotspot1` as they are.

Full setup remains the path for a new or wiped router.

## Factory vs 10.1

A shop-fresh box is often **192.168.88.1**. This PC must already be on that subnet, or you add `192.168.88.x` yourself. After restore, use ether2 and `192.168.10.1`.

## SD cards (RB750)

- Count mounted filesystems only, not empty RouterBOARD slots.
- No mounted card: upload to `flash/hotspot`. Type `retry` after inserting a card.
- Format is `/disk format … file-system=exfat` on the router, not `mkfs` on this PC.

## Lab box

Serial **HJC0A5MY028** is refused unless `mikrotiksetup restore --force` / `mikrotiksetup setup --force`.

## Config

`~/.config/mikrotiksetup/config.json` — path to lokalfi-captive-portal. `mikrotiksetup config` to set it.

## Commands

| Command | Local script |
|---------|----------------|
| `mikrotiksetup setup` | full flow (restores the 17 Sep backup) |
| `mikrotiksetup update` | live site: upload into the current html-directory, then portal network without touching `hsprof1` |
| `mikrotiksetup upload-hotspot` | `scripts/upload-hotspot-to-mikrotik.sh` |
| `mikrotiksetup wan` | `scripts/mikrotik-fix-wan-internet.sh` |
| `mikrotiksetup device-mode` | `scripts/mikrotik-enable-hotspot-device-mode.sh` |
| `mikrotiksetup apply-portal-network` | `scripts/mikrotik-apply-portal-network.sh` |
| `mikrotiksetup refresh-portal-dns` | `scripts/mikrotik-refresh-portal-dns.sh` (Tanay `lokalfi.net` D row) |
| `mikrotiksetup pull-backup` | `scripts/mikrotik-pull-backup.sh` |
| `mikrotiksetup restore` | `scripts/mikrotik-restore-backup.sh` |
| `mikrotiksetup format-sd` | `scripts/mikrotik-format-sd.sh` |
| `mikrotiksetup bootstrap` | portal `docker:bootstrap-mikrotik` |

## Repository

<https://github.com/reiinnprojects/mikrotik-setup>
