# Home lab: DHCP reservations for a two-machine cluster

This guide walks through reserving fixed LAN IP addresses for the two machines
that run the oran-stack Kubernetes cluster at home. Once reservations are in
place, DHCP still assigns the address automatically on boot — but it will always
be the same address.

**Why this matters for oran-stack**

| Inventory field | What breaks if the IP changes |
|-----------------|-------------------------------|
| `ansible_host` | SSH from your laptop, `kubectl` API access, API server TLS certs |
| `control_plane_ip` | OVS VXLAN tunnels between nodes (SCTP / N2 / F1 / E2 traffic) |

The internal pod networks (`10.244.x.x`, `10.200.x.x`) are configured inside the
cluster and are not affected by home-router DHCP. Only the **LAN IPs** of your
two physical machines need to stay stable.

---

## Overview

```
┌─────────────────────────────────────────────────────────────┐
│  Home router (DHCP server)                                  │
│                                                             │
│  Reservation: MAC aa:bb:… → 192.168.1.10  (cp1)            │
│  Reservation: MAC cc:dd:… → 192.168.1.11  (w1)             │
└──────────────┬──────────────────────────┬─────────────────┘
               │                          │
        ┌──────▼──────┐            ┌──────▼──────┐
        │  Machine 1  │            │  Machine 2  │
        │  cp1        │            │  w1         │
        │  control    │            │  worker     │
        │  plane      │            │             │
        └─────────────┘            └─────────────┘
```

**Roles in oran-stack**

| Machine | Ansible name | Inventory group | Suggested reserved IP |
|---------|--------------|-----------------|------------------------|
| Control plane (kubeadm master) | `cp1` | `[control_plane]` | `192.168.1.10` |
| Worker node | `w1` | `[workers]` | `192.168.1.11` |

Replace `192.168.1.x` with whatever subnet your router actually uses
(`192.168.0.x`, `10.0.0.x`, etc.).

---

## Before you start

You need:

- Physical or console access to both machines (or SSH if they are reachable now).
- Admin access to your home router's web UI (or mobile app).
- Both machines connected to the **same LAN** (same Wi‑Fi SSID or Ethernet switch).
- A laptop on the same network to run Ansible playbooks.

**Tip:** Use Ethernet for the cluster nodes if you can. Wi‑Fi works, but the MAC
address you reserve must match the interface the machine actually uses. If a
machine has both Wi‑Fi and Ethernet, pick one and stick with it.

---

## Step 1 — Discover your network details

Run these on **each machine** (or from your laptop for the router gateway).

### 1.1 Find the router (gateway) and subnet

```bash
ip route show default
```

Example output:

```
default via 192.168.1.1 dev enp0s3 proto dhcp src 192.168.1.42 metric 100
```

| Value | Meaning |
|-------|---------|
| `192.168.1.1` | Router / gateway — note this |
| `enp0s3` | Active network interface — note this |
| `192.168.1.42` | Current DHCP address (will change until you reserve) |

Your subnet is the first three octets: `192.168.1.0/24` in this example.

### 1.2 Find the DHCP pool (on the router)

Log into the router admin page (often `http://192.168.1.1` or `http://192.168.0.1`).
Look for **DHCP**, **LAN settings**, or **Connected devices**.

Note the DHCP range, for example `192.168.1.100` – `192.168.1.200`.

**Pick reserved IPs outside that range** so phones and laptops do not collide
with your servers. Common choices:

- `192.168.1.10` and `192.168.1.11`
- `192.168.1.2` and `192.168.1.3` (if the pool starts at `.100`)

### 1.3 Collect MAC addresses from both machines

On **machine 1** (future `cp1`):

```bash
ip link show
```

Find the interface from step 1.1 (e.g. `enp0s3`) and copy the `link/ether` value:

```
2: enp0s3: <BROADCAST,MULTICAST,UP,LOWER_UP> ...
    link/ether 08:00:27:aa:bb:cc brd ff:ff:ff:ff:ff:ff
```

Record:

| Field | Machine 1 (cp1) | Machine 2 (w1) |
|-------|-----------------|----------------|
| Hostname (optional) | `oran-cp1` | `oran-w1` |
| Interface | `enp0s3` | `wlan0` (example) |
| MAC address | `08:00:27:aa:bb:cc` | `…` |
| Reserved IP | `192.168.1.10` | `192.168.1.11` |

Repeat on **machine 2**.

**Wi‑Fi vs Ethernet:** If you reserve the Ethernet MAC but the machine boots on
Wi‑Fi, it will get a different address. Reserve the MAC of the interface you
will actually use.

Shortcut (replace `enp0s3` with your interface):

```bash
ip link show enp0s3 | awk '/link\/ether/ {print $2}'
```

---

## Step 2 — Set friendly hostnames (optional but recommended)

On each machine:

```bash
# Machine 1
sudo hostnamectl set-hostname oran-cp1

# Machine 2
sudo hostnamectl set-hostname oran-w1
```

This does not replace DHCP reservations, but it makes router device lists and
SSH sessions easier to read.

---

## Step 3 — Create DHCP reservations on the router

The exact UI varies by brand. The operation is always the same: **bind a MAC
address to a fixed IPv4 address**.

### Generic procedure

1. Open the router admin UI from a browser on your LAN.
2. Sign in (credentials are often on a sticker on the router).
3. Navigate to one of:
   - **DHCP Reservation** / **Address Reservation** / **Static DHCP**
   - **LAN → DHCP Server → Static Assignment**
   - **Connected Devices → select device → Reserve IP**
4. Add **two** entries:

   | Device | MAC address | Reserved IP |
   |--------|-------------|-------------|
   | cp1 / oran-cp1 | MAC from machine 1 | `192.168.1.10` |
   | w1 / oran-w1 | MAC from machine 2 | `192.168.1.11` |

5. Save / Apply. Some routers reboot or restart DHCP briefly.

### Common router locations

| Brand / type | Where to look |
|--------------|---------------|
| **TP-Link** | Advanced → Network → DHCP Server → Address Reservation |
| **ASUS** | LAN → DHCP Server → Manual Assignment |
| **Netgear** | Advanced → Setup → LAN Setup → Address Reservation |
| **Linksys** | Connectivity → Local Network → DHCP Reservations |
| **Google Nest / Google WiFi** | Google Home app → Wi‑Fi → Settings → Advanced → DHCP IP reservations |
| **eero** | eero app → Settings → Reservations & Port Forwards |
| **UniFi** | Settings → Networks → [your LAN] → DHCP → DHCP Lease Static |
| **OpenWrt** | Network → DHCP and DNS → Static Leases |
| **ISP combo box** | Often under "LAN" or "Home Network"; menu names vary widely |

If your router only offers "pause device" or parental controls but no
reservation, skip to [Alternatives](#alternatives-if-your-router-has-no-dhcp-reservations).

---

## Step 4 — Renew DHCP on both machines

Reservations take effect on the next DHCP lease renewal. Force it on each
machine:

```bash
# Ubuntu / Debian (NetworkManager)
sudo nmcli device reapply $(nmcli -t -f DEVICE,STATE device | awk -F: '$2=="connected"{print $1; exit}')

# Or release and renew (works on many systems)
sudo dhclient -r && sudo dhclient
```

If the address does not change immediately, reboot:

```bash
sudo reboot
```

---

## Step 5 — Verify the reserved IPs

On **each machine**, after reboot or DHCP renew:

```bash
hostname
ip -4 addr show scope global
ip route show default
```

Confirm:

- Machine 1 shows `192.168.1.10` (or whatever you reserved for cp1).
- Machine 2 shows `192.168.1.11`.
- Default gateway matches the router (`192.168.1.1`).

From your **laptop**:

```bash
ping -c 2 192.168.1.10
ping -c 2 192.168.1.11
ssh ubuntu@192.168.1.10 hostname   # should print oran-cp1 or similar
ssh ubuntu@192.168.1.11 hostname
```

If ping works but SSH fails, fix SSH keys/users first — that is separate from
DHCP.

---

## Step 6 — Update the Ansible inventory

In the oran-stack repo on your laptop:

```bash
cp ansible/inventories/hosts.ini.example ansible/inventories/hosts.ini
```

Edit `ansible/inventories/hosts.ini`:

```ini
[control_plane]
cp1  ansible_host=192.168.1.10  control_plane_ip=192.168.1.10  ansible_user=ubuntu

[workers]
w1   ansible_host=192.168.1.11  ansible_user=ubuntu

[k8s_cluster:children]
control_plane
workers

[k8s_cluster:vars]
ansible_ssh_private_key_file=~/.ssh/id_ed25519
ansible_python_interpreter=auto_legacy_silent

[local]
localhost ansible_connection=local
```

Replace `ubuntu` with your SSH username and the IPs with your reserved addresses.

Test Ansible connectivity:

```bash
ansible -i ansible/inventories/hosts.ini k8s_cluster -m ping
```

Expected output:

```
cp1 | SUCCESS => { "ping": "pong" }
w1  | SUCCESS => { "ping": "pong" }
```

---

## Step 7 — Provision and deploy

With stable IPs and a working inventory:

```bash
# Bootstrap Kubernetes, OVS, Multus, etc.
ansible-playbook ansible/playbooks/provision.yml \
  -i ansible/inventories/hosts.ini

# Build images (first time only; requires vault password)
ansible-playbook ansible/playbooks/build_images.yml \
  -i ansible/inventories/hosts.ini --ask-vault-pass

# Deploy the full stack
ansible-playbook ansible/playbooks/deploy.yml \
  -i ansible/inventories/hosts.ini --ask-vault-pass
```

The provision playbook writes `./kubeconfig` pointing at `ansible_host` of cp1.
As long as that IP stays reserved, `kubectl` from your laptop keeps working
across reboots.

---

## Troubleshooting

### Reserved IP not applied after renew

| Check | Action |
|-------|--------|
| Wrong MAC | Compare `ip link` on the machine with the router entry |
| Wrong interface | Machine switched from Ethernet to Wi‑Fi — reserve the active MAC |
| Typo in IP | IP must be inside the LAN subnet but outside conflicting range |
| Old lease cached | Reboot the machine and the router |

### Machine still gets a different IP

Some routers require the device to be **currently connected** when you add the
reservation from the "connected clients" list. Connect the machine, pick it
from the list, and assign the desired IP.

### Cluster was already provisioned with old IPs

1. Update `hosts.ini` with the new reserved IPs.
2. Re-run provision (regenerates API server certs and OVS VXLAN tunnels):

   ```bash
   ansible-playbook ansible/playbooks/provision.yml \
     -i ansible/inventories/hosts.ini
   ```

3. Confirm API access:

   ```bash
   export KUBECONFIG=$(pwd)/kubeconfig
   kubectl get nodes
   ```

### Two machines must reach each other on the LAN

OVS VXLAN tunnels use `control_plane_ip` / `ansible_host` directly. Test
node-to-node connectivity:

```bash
# From cp1
ssh ubuntu@192.168.1.11 ping -c 2 192.168.1.10
```

If this fails, fix Layer-2/Layer-3 routing (VLAN isolation, guest network,
AP client isolation) before deploying the stack.

---

## Alternatives if your router has no DHCP reservations

### A. Static IP in the OS (Netplan on Ubuntu)

On each machine, create `/etc/netplan/01-oran-static.yaml`:

**cp1 (`192.168.1.10`):**

```yaml
network:
  version: 2
  ethernets:
    enp0s3:
      dhcp4: false
      addresses:
        - 192.168.1.10/24
      routes:
        - to: default
          via: 192.168.1.1
      nameservers:
        addresses:
          - 192.168.1.1
          - 8.8.8.8
```

**w1 (`192.168.1.11`):** same file, change the address to `.11`.

```bash
sudo chmod 600 /etc/netplan/01-oran-static.yaml
sudo netplan apply
```

Remove or disable any conflicting Netplan files that still request DHCP on the
same interface.

### B. Local DNS hostnames

If you run Pi-hole, AdGuard Home, or router local DNS, create `A` records:

| Hostname | IP |
|----------|-----|
| `oran-cp1.lan` | `192.168.1.10` |
| `oran-w1.lan` | `192.168.1.11` |

Then in `hosts.ini`:

```ini
cp1  ansible_host=oran-cp1.lan  control_plane_ip=oran-cp1.lan  ...
w1   ansible_host=oran-w1.lan  ...
```

Hostnames still require stable IPs behind the DNS records.

---

## Quick reference checklist

- [ ] Gateway and subnet identified (`ip route`)
- [ ] DHCP pool noted; reserved IPs chosen outside the pool
- [ ] MAC addresses collected from both machines
- [ ] Two DHCP reservations created on the router
- [ ] Both machines renewed DHCP or rebooted
- [ ] `ip addr` shows the expected reserved IPs
- [ ] `ansible … -m ping` succeeds
- [ ] `hosts.ini` updated with reserved IPs
- [ ] `provision.yml` and `deploy.yml` run successfully

---

## Related docs

- [README — Option B: Bring Your Own machines](../README.md#option-b-bring-your-own-machines)
- [Inventory template](../ansible/inventories/hosts.ini.example)
