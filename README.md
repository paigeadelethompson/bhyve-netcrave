# FreeBSD bhyve VM Provisioning Infrastructure

This project provides scripts and configuration to create and manage virtual machines (VMs) running **FreeBSD** and **Void Linux** on a FreeBSD host using `bhyve` (the BSD hypervisor).

## Related Posts

- [Automating bhyve Virtualization on FreeBSD with ZFS and FIBs](https://paige.bio/posts/automating-bhyve-virtualization-on-freebsd-with-zfs-and-fibs/)
- [Evolving my FreeBSD Hypervisor: Lessons from 20 Years of Linux](https://paige.bio/posts/evolving-my-freebsd-hypervisor-lessons-from-20-years-of-linux/)

## Overview

The infrastructure automates:
- **VM Provisioning**: Create isolated VMs with dedicated ZFS storage
- **Network Segmentation**: Multiple FIBs (Forwarding Information Bases) for traffic isolation
- **Guest OS Support**: FreeBSD 13.2/14.x and Void Linux (musl)
- **Init Systems**: FreeBSD rc.d and runit (Void)

## Network Architecture

The host is configured as a network gateway with three segmented networks using FIB-based routing for isolation:

| Network | FIB | Primary Interface | Subnet | Purpose |
|---------|-----|-------------------|--------|---------|
| SWARM   | 8   | igb0              | 198.18.2.0/23 | Docker Swarm infrastructure |
| HOME    | 10  | igb1              | 192.168.65.129/25 | Home servers |
| TAILSCALE | 12 | tap4 (via bridge2) | 192.0.2.0/30 | Tailscale VPN |

### FIB Routing and ePAIR Interfaces

The `epair*` interfaces provide **inter-FIB routing** by connecting each network's dedicated FIB to the **core FIB 0**:

| ePAIR Pair | Core FIB (FIB 0) | Network FIB | Purpose |
|------------|------------------|-------------|---------|
| epair0a/b | epair0a (192.0.0.0/31) | epair0b (FIB 8) | Swarm gateway to core routing table |
| epair1a/b | epair1a (192.0.0.2/31) | epair1b (FIB 10) | Home servers gateway to core routing table |
| epair2a/b | epair2a (192.0.0.4/31) | epair2b (FIB 12) | Tailscale gateway to core routing table |

Traffic flow:
1. VMs in a network reach the VRF gateway (`epairXa`) via bridge
2. The gateway routes traffic through FIB-specific routes defined in rc.conf
3. Traffic reaches the "core" side of the epair interface (`epairXb`)
4. From there, it's routed according to FIB 0's routing table

**Null routes prevent direct communication between isolated networks:**
- FIB 8 → FIB 0/10: blocked (swarm can't reach home/LAN)
- FIB 10 → FIB 8: blocked (home can't reach swarm)  
- FIB 12 → FIB 0: blocked (TailScale can't reach LAN)

## Directory Structure

```
.
├── README.md                 # This file
├── create_freebsd_vm.sh      # Script to provision FreeBSD VMs
├── create_void_vm.sh         # Script to provision Void Linux VMs
├── templates/                # VM template configurations
│   ├── fbsd-dev.conf         # FreeBSD dev (4CPU, 2GB RAM)
│   ├── home.conf             # Home server (4CPU, 4GB RAM)
│   ├── swarm.conf            # Docker Swarm (4CPU, 2GB RAM)
│   └── tailscale.conf        # Tailscale VPN (2CPU, 512MB RAM)
├── rc.conf                   # Host network/service configuration
├── loader.conf               # Boot loader configuration
├── sysctl.conf               # Kernel parameters for IP forwarding
└── vtysh                     # FRRouting/BGP configuration
```

## Requirements

### Host System

- FreeBSD host with bhyve support (base system - no package needed)
- ZFS pool named `zroot`
- Kernel modules: `nmdm`, `cryptodev`, `fusefs` (loaded via `loader.conf`)
- Network interface for external connectivity
- Sufficient CPU/RAM for target VM count

### Required Packages

```bash
pkg install -y vm-bhyve bhyve-firmware lldpd
```

- `vm-bhyve` - Provides the `vm(8)` command for VM management
- `bhyve-firmware` - UEFI firmware for VM boot (required for templates using `loader="uefi"`)
- `lldpd` - LLDP daemon (referenced in `rc.conf`)

### vm-bhyve Setup

After installing `vm-bhyve`, configure it in `/etc/rc.conf`:

```bash
# Using zroot pool (common default)
vm_enable="YES"
vm_dir="zfs:zroot/vm"

# Or using a different ZFS pool
# vm_dir="zfs:poolname/vm"
```

Optionally increase shutdown timeouts for proper VM cleanup:

```bash
# /etc/sysctl.conf
kern.init_shutdown_timeout=120

# /etc/rc.conf
rcshutdown_timeout=120
```

Then initialize the VM directory:
```bash
vm init
```

### sysctl.conf

Enable IP forwarding and disable source address validation for VRF routing:

```bash
net.inet6.ip6.forwarding=1
net.inet.ip.forwarding=1
net.inet6.ip6.source_address_validation=0
```

## Usage

### Create a FreeBSD VM

```bash
./create_freebsd_vm.sh <vm_name> [options]
```

**Options:**
- `-t, --template <name>`   Template to use (default: freebsd)
- `-i, --interface <tap>`   TAP interface for networking
- `-h, --help`              Show help

**Examples:**
```bash
# Create VM with default template and FreeBSD version from .env
./create_freebsd_vm.sh my-vm

# Create with specific template and network interface
./create_freebsd_vm.sh swarm-node -t swarm -i tap0
```

### Create a Void Linux VM

```bash
./create_void_vm.sh <vm_name> [options]
```

**Options:**
- `-t, --template <name>`   Template to use (default: void)
- `-i, --interface <tap>`   TAP interface for networking
- `-h, --help`              Show help

### Start/Stop VMs

```bash
# Start a VM
vm start -f <vm_name>

# Stop a VM
vm stop <vm_name>

# List VMs
vm list

# Access console
vm console <vm_name>
```

## Configuration Variables

Both scripts use the following configurable variables (defined at the top of each script):

| Variable | Default | Description |
|----------|---------|-------------|
| `VM_DIR` | `/vm` | Directory for VM storage and SSH keys |
| `STORAGE_POOL` | `storage` | ZFS pool name for VM disks (e.g., `zroot/vm`) |
| `DIST_DIR` | `/mnt/dist` | Directory for installation sources; Linux kernel source must be cloned here manually before creating Void VMs |
| `FREEBSD_INSTALL_DIR` | `/mnt/freebsd-install` | Mount point for FreeBSD VM installation |
| `VOID_INSTALL_DIR` | `/mnt/void-install` | Mount point for Void Linux VM installation |

## VM Configuration

Each template config specifies:
- CPU topology (sockets, cores, threads)
- Memory allocation
- Disk type and size (`virtio-blk` on ZFS zvol)
- Network interface type (`virtio-net`) and bridge association
- UEFI boot with serial console

### Template Details

| Template | vCPUs | Memory | Boot | Network |
|----------|-------|--------|------|---------|
| fbsd-dev | 4 (2c/2t) | 2GB | UEFI | bridge1 (home) |
| home     | 4 (2c/2t) | 4GB | UEFI | bridge1 (home) |
| swarm    | 4 (2c/2t) | 2GB | UEFI | bridge0 (swarm) |
| tailscale| 2 (1c/2t) | 512MB | UEFI | bridge1 (home) |

### Template Files

Copy the template files from `templates/` to `/zroot/vm/.templates/`:

```bash
cp templates/*.conf /zroot/vm/.templates/
```

The templates are referenced by name in the VM creation scripts (e.g., `-t swarm`, `-t home`).

## Host Configuration

### rc.conf

Full host configuration for the FreeBSD gateway. Key sections:

#### Services Enabled
```bash
chronyd_enable=YES          # NTP time sync
dnsmasq_enable=YES          # DNS/DHCP server
sshd_enable=YES             # Remote SSH access
zfs_enable=YES              # ZFS support
gateway_enable=YES          # IP forwarding enabled
lldpd_enable=YES            # LLDP network discovery
linux_enable=YES            # Linux compatibility
pf_enable=YES               # PF firewall
nfs_server_enable=YES       # NFS server for /usr/src
vm_enable=YES               # bhyve VM management
```

#### Network Interfaces (FIB Assignment)
| Interface | FIB | IP Address | Purpose |
|-----------|-----|------------|---------|
| ix1 | 0 | 192.168.1.128/24 | LAN (external) |
| igb0 | 8 | 198.18.2.1/23 | Docker Swarm network |
| igb1 | 10 | 192.168.65.129/25 | Home servers |
| epair0a/b | 0/8 | 192.0.0.0/31 | Swarm VRF gateway pair |
| epair1a/b | 0/10 | 192.0.0.2/31 | Home VRF gateway pair |
| epair2a/b | 0/12 | 192.0.0.4/31 | Tailscale VRF gateway pair |

#### Virtual Bridges
| Bridge | IP | FIB | Members | Purpose |
|--------|-----|-----|---------|---------|
| bridge0 | 198.18.0.1/23 | 8 | igb0, tap0-2 | Swarm VMs |
| bridge1 | 192.168.64.129/25 | 10 | igb1, tap3, tap5 | Home/Tailscale VMs |
| bridge2 | 192.0.2.1/30 | 12 | tap4 | Tailscale VPN |

#### Routing (FIB 0 - Default)
```bash
# Route swarm traffic through VRF gateway
route_fib0_swarm="-fib 0 -net 198.18.0.0/23 192.0.0.1"

# Route home traffic through VRF gateway  
route_fib0_home="-fib 0 -net 192.168.64.128/24 192.0.0.3"

# Route Tailscale through VRF gateway
route_fib0_ts="-fib 0 -net 192.0.2.0/30 192.0.0.5"
route_fib0_egr_ts="-fib 0 -net 100.64.0.0/10 192.0.0.5"

# Default route via LAN
route_fib0_default="-fib 0 default 192.168.1.1"
```

#### FIB-Specific Default Routes
- **FIB 8** (Swarm): `default 192.0.0.0`
- **FIB 10** (Home): `default 192.0.0.2`
- **FIB 12** (Tailscale): `default 192.0.0.4`

#### Null Routes (Isolation)
```bash
# Prevent swarm->home/LAN traffic
route_fib8_null_fib0="-fib 8 -net 192.168.0.0/16 -reject"

# Prevent home->swarm traffic
route_fib10_null_fib8="-fib 10 -net 198.18.0.0/15 -reject"

# Prevent Tailscale->LAN traffic
route_fib12_null_fib0="-fib 12 -net 192.168.0.0/20 -reject"
```

### loader.conf
Boot-time kernel settings:
- `boot_multicons=YES`, `boot_serial=YES` - Serial console (115200 baud)
- `zfs_load=YES`, `cryptodev_load=YES` - Load kernel modules at boot
- `net.fibs=256` - Enable 256 Forwarding Information Bases
- `kern.racct.enable=1` - Resource accounting

### FRRouting Configuration

This project includes an FRRouting (FRR) configuration for BGP route advertisement. The `vtysh` file contains:

```
frr version 10.3
frr defaults traditional

# Access control - deny all traffic
access-list private seq 5 deny any

# Prefix lists for filtering routes to advertise
ip prefix-list PL_64 seq 5 permit 192.168.64.128/29
ip prefix-list ADVERTISE_ONLY seq 5 permit 192.168.64.128/29
ip prefix-list SUBNET_TO_ADVERTISE seq 5 permit 192.168.64.128/29

# Interfaces to participate in routing
interface bridge1
exit
!
interface ix1
exit

# Route maps for policy-based routing
route-map ADV_64 permit 10
 match ip address prefix-list PL_64
exit
!
route-map ONLY_SPECIFIC_SUBNET permit 10
 match ip address prefix-list SUBNET_TO_ADVERTISE
exit
```

**Purpose:**
- Advertises the `192.168.64.128/29` subnet to BGP peers via FIB 10 (home network)
- Uses prefix lists for route filtering to control which subnets are advertised
- Interfaces bridge1 and ix1 participate in the routing protocol

**Note:** This file is a reference configuration. Load it with `vtysh -f vtysh` or import into your FRR installation.

## Development Notes

### Avahi Integration
VMs use `avahi-autoipd` for `.local` hostname resolution on link-local addresses.

## License

This project is provided as-is for personal/home use.
