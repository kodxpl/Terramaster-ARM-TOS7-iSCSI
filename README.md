# iSCSI target on TerraMaster TOS 7 (ARM)

> **TL;DR:** TOS 7 on ARM can't export iSCSI and TerraMaster won't add it back. Install the userspace target **tgt** over SSH and manage exports with `tnas-iscsi.sh`.
>
> 1. Enable SSH: Control Panel → SNMP & Terminal, port **9222**.
> 2. `apt update && apt install --no-install-recommends tgt`
> 3. `systemctl enable --now tgt`
> 4. Run `./tnas-iscsi.sh` and create an export, allowing your client's IP.
> 5. Connect from the client on port 3260.
>
> Can't see the target from the client? The ACL is blocking its IP; see Troubleshooting.

## Overview

TOS 7 for ARM ships without iSCSI Manager and without the kernel iSCSI target module (`iscsi_target_mod`), so the NAS can only attach iSCSI disks, not export them. Still ARM has plenty of horsepower to run this small service. This guide adds export support with **tgt**, a userspace iSCSI target installed over SSH, plus the menu script `tnas-iscsi.sh` to manage exports.

TerraMaster confirms this is permanent. The [TOS 7 ARM release announcement](https://forum.terra-master.com/en/viewtopic.php?p=59311) lists iSCSI Manager among the removed apps. In the [TOS 7.0.1078 Beta (ARM) thread](https://forum.terra-master.com/en/viewtopic.php?p=58939), TerraMaster support replied that these apps will not return to ARM versions for the foreseeable future.

# **Important note**

- **Update TOS version** A TOS update may remove tgt or its config. Keep a copy of `/etc/tgt/conf.d/` and the script off the NAS.
- **One client per LUN.** Two machines mounting the same NTFS or ext4 LUN will corrupt it.
- **Never run `apt upgrade` or `apt full-upgrade` on TOS.**
- All commands run as root which is main user on TerraMaster (enable SSH in Control Panel).

## Prerequisite: enable SSH

> **Nothing in this runbook works without SSH.** Every step runs in an SSH session on the NAS.

1. In the TOS web interface, open **Control Panel → SNMP & Terminal** and enable the **SSH** server. The default SSH port is **9222**, not 22.
2. If your PC is in a different subnet than the NAS, **uncheck "Allow Telnet/SSH access only within the local network"**, otherwise the connection is refused.
3. From your PC, connect on port 9222 with an admin (no need to switch to root as main user account is root already):

```bash
ssh -p 9222 admin_user@NAS_IP
```

## 1. Check the system

These commands show which Debian base TOS uses and confirm the kernel target is missing.

```bash
cat /etc/debian_version
cat /etc/os-release /usr/lib/os-release 2>/dev/null
ldd --version | head -1
dpkg --print-architecture
cat /etc/apt/sources.list; ls /etc/apt/sources.list.d/
modprobe iscsi_target_mod   # expected on TOS 7 ARM: Module not found
```

The glibc version from `ldd` identifies the Debian release

## 2. Install tgt

Refresh the package lists, simulate the install, and install only if the simulation adds new packages without removing or upgrading system ones. TOS asks for a `yes` confirmation on every `apt install`.

```bash
apt update
apt install tgt
```

Never run `apt upgrade` or `apt full-upgrade` on TOS.

## 3. Start tgt and enable it at boot

```bash
systemctl enable --now tgt
pgrep -a tgtd                     # tgtd must be running
ss -ltn | grep 3260               # listening on the iSCSI port
grep include /etc/tgt/targets.conf   # must contain: include /etc/tgt/conf.d/*.conf
```

If the TOS firewall is on, allow TCP port 3260 in Control Panel.

## 4. Manage exports with tnas-iscsi.sh

Copy the script to the NAS, for example to `/Volume1/public`, and run it:

```bash
chmod +x tnas-iscsi.sh
./tnas-iscsi.sh
```

Every change applies immediately and is saved to `/etc/tgt/conf.d/<name>.conf`, so it survives a reboot.

| Menu option | What it does |
| --- | --- |
| 1 List exports | Target name, image file and size, allowed IPs, connected clients, config file |
| 2 Create export | Pick a volume and size; the image goes to `/VolumeN/iscsi/<name>.img` (folder created if missing, copy-on-write off on btrfs) |
| 3 Add ACL rule | Allow an IP, a subnet such as `172.19.20.0/24`, or `ALL` |
| 4 Remove ACL rule | Refuses to remove the last entry, which would open the target to everyone after reboot |
| 5 Delete export | Confirm by typing the name; the image file is deleted only if you also type `DELETE` |
| 6 Load missing targets | Runs `tgt-admin -e` to load configs that are not active |

New targets are named `iqn.2026-10.lan.tnas:<name>`. Change `IQN_PREFIX` at the top of the script to use another prefix.

## 5. Connect a client

**Windows:** open iSCSI Initiator, enter the NAS IP under Quick Connect, and connect. Initialize and format the new disk in Disk Management.

**Linux:**

```bash
iscsiadm -m discovery -t st -p NAS_IP
iscsiadm -m node --login
lsblk                              # the new disk appears here
```

Partition and format the disk on the client, never on the NAS.

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| `no portals found` on discovery, or login fails with `failed to receive a PDU` | The client's IP is not in the ACL; tgt hides the target from it. Run `ip route get NAS_IP` on the client and add the address after `src` with menu option 3. |
| `tgtadm --mode target --op show` lists nothing | Config was not loaded. Run `tgt-admin -e -v` to load it and see the error. |
| `Unable to locate package tgt` | Run `apt update` first; if it still fails, add the Debian repository from step 2. |
| Targets gone after a reboot | Run `systemctl enable tgt`, then menu option 6. |
| tgt missing after a TOS update | Repeat steps 2 and 3. Configs in `/etc/tgt/conf.d/` reload automatically if they survived; otherwise restore your copy. |

To test an ACL problem quickly, open the target to everyone and close it again afterwards:

```bash
tgtadm --lld iscsi --mode target --op bind   --tid 1 -I ALL
tgtadm --lld iscsi --mode target --op unbind --tid 1 -I ALL
```
