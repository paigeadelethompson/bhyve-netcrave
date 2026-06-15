#!/usr/bin/env bash

set -e

# Load environment variables from .env file (or use defaults)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/.env" ]; then
    source "$SCRIPT_DIR/.env"
fi

# Function to handle cleanup on exit
cleanup() {
    local exit_code=$?
    echo "Cleaning up..."

    # First try to exit chroot if we're in it
    if [ "$(pwd)" = "$VOID_INSTALL_DIR" ]; then
        cd ${VM_DIR} || cd /
    fi

    # Wait a moment for any processes to finish
    sleep 1

    # Unmount in reverse order of mounting, with retries
    for mount_point in "$VOID_INSTALL_DIR/usr/src/linux" \
                      "$VOID_INSTALL_DIR/proc" \
                      "$VOID_INSTALL_DIR/sys" \
                      "$VOID_INSTALL_DIR/dev" \
                      "$VOID_INSTALL_DIR/boot/efi" \
                      "$VOID_INSTALL_DIR"; do
        if mount | grep -q "$mount_point"; then
            echo "Unmounting $mount_point..."
            for i in {1..3}; do
                if umount "$mount_point" 2>/dev/null; then
                    break
                fi
                echo "Retry $i: Waiting for $mount_point to be unmountable..."
                sleep 2
            done
        fi
    done
    
    # If we failed and VM exists, destroy it
    if [ $exit_code -ne 0 ] && [ -n "$VM_NAME" ]; then
        echo "Installation failed for VM '${VM_NAME}' with template '${VM_TEMPLATE}', destroying VM..."
        vm destroy -f "$VM_NAME" || echo "Warning: Failed to destroy VM ${VM_NAME}"
    fi
    
    exit $exit_code
}

# Set up trap to call cleanup function on script exit
trap cleanup EXIT

# Check if nmdm kernel module is loaded, if not load it
if ! kldstat -m nmdm > /dev/null 2>&1; then
    echo "Loading nmdm kernel module..."
    kldload nmdm || { echo "Failed to load nmdm kernel module"; exit 1; }
fi

# Parse command line arguments
VM_TEMPLATE="void" # Default template
TAP_INTERFACE="" # Default empty tap interface

usage() {
    echo "Usage: $0 <vm_name> [options]"
    echo "Options:"
    echo "  -t, --template <template>   Specify the VM template to use (default: void)"
    echo "  -i, --interface <tap>       Specify the tap interface to use (e.g. tap3)"
    echo "  -h, --help                  Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 my-vm                    # Create VM 'my-vm' with default 'void' template"
    echo "  $0 my-vm -t freebsd         # Create VM 'my-vm' with 'freebsd' template"
    echo "  $0 my-vm -i tap3            # Create VM 'my-vm' using tap3 network interface"
    exit 1
}

# Check if at least one argument is provided
if [ $# -lt 1 ]; then
    usage
fi

VM_NAME="$1"
shift

# Parse remaining arguments
while [ $# -gt 0 ]; do
    case "$1" in
        -t|--template)
            VM_TEMPLATE="$2"
            shift 2
            ;;
        -i|--interface)
            TAP_INTERFACE="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

echo "Creating VM with name: ${VM_NAME}, template: ${VM_TEMPLATE}"

# Create the VM
vm create -t ${VM_TEMPLATE} ${VM_NAME} || { echo "Failed to create VM"; exit 1; }
ssh-keygen -t ed25519 -f ${VM_DIR}/${VM_NAME}/id_ed25519 -N "" || { echo "Failed to generate SSH key"; exit 1; }
# Prepare zvol
zfs set volmode=geom ${STORAGE_POOL}${VM_DIR}/${VM_NAME}/disk0 || { echo "Failed to set zvol mode"; exit 1; }

# Partition disk
gpart create -s gpt /dev/zvol/${STORAGE_POOL}/${VM_DIR}/${VM_NAME}/disk0 || { echo "Failed to create GPT partition table"; exit 1; }
gpart add -t efi -s 256M /dev/zvol/${STORAGE_POOL}/${VM_DIR}/${VM_NAME}/disk0 || { echo "Failed to add EFI partition"; exit 1; }
gpart add -t freebsd-ufs /dev/zvol/${STORAGE_POOL}/${VM_DIR}/${VM_NAME}/disk0 || { echo "Failed to add UFS partition"; exit 1; }

# Format partitions
newfs_msdos /dev/zvol/${STORAGE_POOL}/${VM_DIR}/${VM_NAME}/disk0p1 || { echo "Failed to format EFI partition"; exit 1; }
newfs /dev/zvol/${STORAGE_POOL}/${VM_DIR}/${VM_NAME}/disk0p2 || { echo "Failed to format UFS partition"; exit 1; }

# Create mount points and mount partitions
mkdir -p ${VOID_INSTALL_DIR} || { echo "Failed to create mount point"; exit 1; }
mount /dev/zvol/${STORAGE_POOL}/${VM_DIR}/${VM_NAME}/disk0p2 ${VOID_INSTALL_DIR} || { echo "Failed to mount root partition"; exit 1; }
mkdir -p ${VOID_INSTALL_DIR}/boot/efi || { echo "Failed to create EFI mount point"; exit 1; }
mount -t msdosfs /dev/zvol/${STORAGE_POOL}/${VM_DIR}/${VM_NAME}/disk0p1 ${VOID_INSTALL_DIR}/boot/efi || { echo "Failed to mount EFI partition"; exit 1; }

# Check if rootfs archive exists in ${DIST_DIR}, if not download it
if [ ! -f "${DIST_DIR}/${VOID_ROOTFS_FILE}" ]; then
    mkdir -p ${DIST_DIR} || { echo "Failed to create ${DIST_DIR} directory"; exit 1; }
    wget -O ${DIST_DIR}/${VOID_ROOTFS_FILE} https://repo-default.voidlinux.org/live/current/${VOID_ROOTFS_FILE} || { echo "Failed to download rootfs"; exit 1; }
fi

# Download and extract rootfs
cd ${VOID_INSTALL_DIR} || { echo "Failed to change to mount directory"; exit 1; }

cp ${DIST_DIR}/${VOID_ROOTFS_FILE} . || { echo "Failed to copy rootfs archive"; exit 1; }
bsdtar -x --no-xattrs -f ${VOID_ROOTFS_FILE} || { echo "Failed to extract rootfs"; exit 1; }
rm ${VOID_ROOTFS_FILE} || { echo "Failed to remove rootfs archive"; exit 1; }

# Prepare chroot
mount -t linprocfs linprocfs ${VOID_INSTALL_DIR}/proc || { echo "Failed to mount proc"; exit 1; }
mount -t linsysfs linsysfs ${VOID_INSTALL_DIR}/sys || { echo "Failed to mount sys"; exit 1; }
mount -t devfs devfs ${VOID_INSTALL_DIR}/dev || { echo "Failed to mount dev"; exit 1; }
cat /etc/resolv.conf | grep "nameserver" >> ${VOID_INSTALL_DIR}/etc/resolv.conf || { echo "Failed to copy resolv.conf"; exit 1; }

# Get Void Linux repo IP address and add to hosts
echo "Getting Void Linux repo IP address..."
REPO_IP=$(dig @4.2.2.1 d-hel-fi.m.voidlinux.org -t A +short)
if [ -n "$REPO_IP" ]; then
    echo "Found repo IP: $REPO_IP"
    # Add to hosts file
    echo "$REPO_IP repo-default.voidlinux.org" >> /etc/hosts
    echo "$REPO_IP repo-default.voidlinux.org" >> ${VOID_INSTALL_DIR}/etc/hosts
else
    echo "Warning: Could not determine Void Linux repo IP address"
fi

# Create /etc/fstab for the VM
cat << EOF > ${VOID_INSTALL_DIR}/etc/fstab || { echo "Failed to create fstab"; exit 1; }
/dev/vda2 / ufs defaults 0 1
/dev/vda1 /boot/efi msdos defaults 0 2
EOF

# add ssh pub key to authorized_keys
mkdir -p ${VOID_INSTALL_DIR}/root/.ssh
cat ${VM_DIR}/${VM_NAME}/id_ed25519.pub >> ${VOID_INSTALL_DIR}/root/.ssh/authorized_keys

# Create script to run inside chroot
cat << EOF > ${VOID_INSTALL_DIR}/setup.sh || { echo "Failed to create setup script"; exit 1; }
#!/bin/bash
set -e


# VM template used for creation
VM_TEMPLATE="${VM_TEMPLATE}"
VM_NAME="${VM_NAME}"

# Print VM info
echo "Setting up VM '${VM_NAME}' created with template '${VM_TEMPLATE}'"

# Create ignore.conf to prevent package installation
mkdir -p /etc/xbps.d
cat << 'IGNOREEOF' > /etc/xbps.d/ignore.conf
ignorepkg=linux
ignorepkg=linux-headers
ignorepkg=grub
ignorepkg=efibootmgr
ignorepkg=linux-firmware
ignorepkg=linux-firmware-amd
ignorepkg=linux-firmware-broadcom
ignorepkg=linux-firmware-dvb
ignorepkg=linux-firmware-intel
ignorepkg=linux-firmware-network
ignorepkg=linux-firmware-nvidia
ignorepkg=linux-firmware-qualcomm
ignorepkg=wifi-firmware 
ignorepkg=wpa_supplicant
ignorepkg=zd1211-firmware
ignorepkg=linux6.12 
ignorepkg=void-artwork
ignorepkg=u-boot-tools 
ignorepkg=uboot-mkimage 
ignorepkg=dracut
ignorepkg=usbutils
ignorepkg=libusb
ignorepkg=iw
IGNOREEOF

xbps-install -Suy

xbps-install -y                                     \
acl acpid ada attr base-container-full              \
base-files base-system bash bc nano                 \
binutils binutils-doc binutils-libs bison           \
btrfs-progs bzip2 bzip2-devel c-ares                \
ca-certificates containerd coreutils cpio           \
dash dbus-libs device-mapper dhcpcd                 \
diffutils dnsmasq dnssec-anchors docker             \
docker-cli docker-compose dosfstools                \
e2fsprogs e2fsprogs-libs elfutils-devel             \
ethtool eudev eudev-libudev expat                   \
f2fs-tools file findutils flex gawk                 \
gcc gcc-ada gdbm git lldpd                          \
gmp gmp-devel gnutls grep gzip                      \
htop hwids iana-etc icu-libs inih                   \
iproute2 iptables iputils jansson json-c kbd        \
kernel-libc-headers kmod kpartx less                \
libada libada-devel libaio                          \
libarchive libatomic libatomic-devel                \
libblkid libbpf libcap libcap-ng libcap-progs       \
libcap libcap-ng libcap-progs libcrypto3            \
libcurl libdb libdebuginfod libedit                 \
libelf libev libevent libfdisk libffi               \
libfl-devel libgcc libgcc-devel                     \
libidn2 libkeyutils libkmod liblastlog2             \
libldap libldns liblz4 liblzma                      \
liblzma-devel libmagic libmnl libmount              \
libmpc libmpc-devel libnetfilter_conntrack          \
libnfnetlink libnfsidmap libnftables libnftnl       \
libnl3 libparted libpcap libpcre libpcre2           \
libpsl libreadline8 libsasl libseccomp              \
libselinux libsepol libsmartcols libsodium          \
libssh2 libssl3 libstdc++                           \
libstdc++-devel libtasn1 libtirpc                   \
libunbound libunistring liburcu                     \
libuuid libxbps libxml2 libxxHash                   \
libzstd libzstd-devel linux-base lzo m4             \
make man-pages mdocml mit-krb5-libs                 \
moby mpfr mpfr-devel musl                           \
musl-devel musl-fts musl-obstack ncurses            \
ncurses-base ncurses-libs nettle nfs-utils          \
nftables nghttp2 ntp nvi openssh                    \
openssl openssl-devel p11-kit pahole                \
pam pam-base pam-libs parted pciutils               \
perl perl-Authen-SASL perl-Convert-BinHex           \
perl-Digest-HMAC perl-IO-Socket-SSL perl-IO-stringy \
perl-MIME-tools perl-MailTools perl-Net-SMTP-SSL    \
perl-Net-SSLeay perl-TimeDate perl-URI pkg-config   \
popt procps-ng public-suffix python3                \
removed-packages rpcbind rsync                      \
run-parts runc runit runit-void sed                 \
shadow socklog socklog-void sqlite                  \
sudo tar tini traceroute tzdata                     \
util-linux util-linux-common which xbps             \
xbps-triggers xfsprogs xz avahi avahi-autoipd

# Enable services 
ln -sf /etc/sv/dnsmasq /etc/runit/runsvdir/default/
ln -sf /etc/sv/docker /etc/runit/runsvdir/default/
ln -sf /etc/sv/nanoklogd /etc/runit/runsvdir/default/
ln -sf /etc/sv/socklog-unix /etc/runit/runsvdir/default/
ln -sf /etc/sv/sshd /etc/runit/runsvdir/default/
ln -sf /etc/sv/avahi-daemon /etc/runit/runsvdir/default/
ln -sf /etc/sv/lldpd /etc/runit/runsvdir/default/

# Configure SSH server
cat << 'SSHCONFIG' > /etc/ssh/sshd_config
Include /etc/ssh/sshd_config.d/*.conf
Port 22
AddressFamily any
ListenAddress 0.0.0.0
ListenAddress ::
PubkeyAuthentication yes
AuthorizedKeysFile      .ssh/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM yes
PrintMotd no
Subsystem       sftp    /usr/libexec/sftp-server
SSHCONFIG

# rc.conf
cat << 'RCCONFEOF' > /etc/rc.conf
HOSTNAME="${VM_NAME}"
HARDWARECLOCK="UTC"
TIMEZONE="America/Los_Angeles"
KEYMAP="en"
FONT="lat9w-16"
CGROUP_MODE=unified
SEEDRNG_SKIP_CREDIT=false
RCCONFEOF

# Create rc.local script for network configuration
cat << 'RCLOCALEOF' > /etc/rc.local
#!/bin/sh

ip link set dev eth0 up
avahi-autoipd -D -s --force-bind eth0
echo "nameserver 127.0.0.1" > /etc/resolv.conf

RCLOCALEOF
chmod +x /etc/rc.local

cd /usr/src/linux

if [ ! -f ".config" ]; then
    make mrproper
    make clean
    make defconfig
    make kvm_guest.config
    make mod2yesconfig

    scripts/config -e CONFIG_HZ_100
    scripts/config -e CONFIG_PREEMPT
    scripts/config -e CONFIG_BOOT_CONFIG
    scripts/config -e CONFIG_HZ_PERIODIC
    scripts/config -e CONFIG_MSDOS_FS
    scripts/config -e CONFIG_VFAT_FS
    scripts/config -e CONFIG_EXFAT_FS
    scripts/config -e CONFIG_BTRFS_FS
    scripts/config -e CONFIG_UFS_FS
    scripts/config -e CONFIG_UFS_FS_WRITE
    scripts/config -e CONFIG_SCSI_VIRTIO
    scripts/config -e CONFIG_HW_RANDOM_VIRTIO
    scripts/config -e CONFIG_NFS_FS
    scripts/config -e CONFIG_NFS_V2
    scripts/config -e CONFIG_NFS_V3
    scripts/config -e CONFIG_NFS_V3_ACL
    scripts/config -e CONFIG_NFS_V4
    scripts/config -e CONFIG_NFS_SWAP
    scripts/config -e CONFIG_NFS_V4_1
    scripts/config -e CONFIG_NFS_V4_2
    scripts/config -e CONFIG_HAVE_KERNEL_GZIP
    scripts/config -e CONFIG_KERNEL_GZIP
    scripts/config -e CONFIG_NET_KEY
    scripts/config -e CONFIG_NET_HANDSHAKE_KUNIT_TEST
    scripts/config -e CONFIG_NET_IPIP
    scripts/config -e CONFIG_NET_IPGRE_DEMUX
    scripts/config -e CONFIG_NET_IP_TUNNEL
    scripts/config -e CONFIG_NET_IPGRE
    scripts/config -e CONFIG_NET_IPVTI
    scripts/config -e CONFIG_NET_UDP_TUNNEL
    scripts/config -e CONFIG_NET_FOU
    scripts/config -e CONFIG_NET_DSA
    scripts/config -e CONFIG_NET_DSA_TAG_NONE
    scripts/config -e CONFIG_NET_DSA_TAG_AR9331
    scripts/config -e CONFIG_NET_DSA_TAG_BRCM_COMMON
    scripts/config -e CONFIG_NET_DSA_TAG_BRCM
    scripts/config -e CONFIG_NET_DSA_TAG_BRCM_PREPEND
    scripts/config -e CONFIG_NET_DSA_TAG_HELLCREEK
    scripts/config -e CONFIG_NET_DSA_TAG_GSWIP
    scripts/config -e CONFIG_NET_DSA_TAG_DSA_COMMON
    scripts/config -e CONFIG_NET_DSA_TAG_DSA
    scripts/config -e CONFIG_NET_DSA_TAG_EDSA
    scripts/config -e CONFIG_NET_DSA_TAG_MTK
    scripts/config -e CONFIG_NET_DSA_TAG_KSZ
    scripts/config -e CONFIG_NET_DSA_TAG_OCELOT
    scripts/config -e CONFIG_NET_DSA_TAG_OCELOT_8021Q
    scripts/config -e CONFIG_NET_DSA_TAG_QCA
    scripts/config -e CONFIG_NET_DSA_TAG_RTL4_A
    scripts/config -e CONFIG_NET_DSA_TAG_RTL8_4
    scripts/config -e CONFIG_NET_DSA_TAG_RZN1_A5PSW
    scripts/config -e CONFIG_NET_DSA_TAG_LAN9303
    scripts/config -e CONFIG_NET_DSA_TAG_SJA1105
    scripts/config -e CONFIG_NET_DSA_TAG_TRAILER
    scripts/config -e CONFIG_NET_DSA_TAG_VSC73XX_8021Q
    scripts/config -e CONFIG_NET_DSA_TAG_XRS700X
    scripts/config -e CONFIG_NET_SCH_HTB
    scripts/config -e CONFIG_NET_SCH_HFSC
    scripts/config -e CONFIG_NET_SCH_PRIO
    scripts/config -e CONFIG_NET_SCH_MULTIQ
    scripts/config -e CONFIG_NET_SCH_RED
    scripts/config -e CONFIG_NET_SCH_SFB
    scripts/config -e CONFIG_NET_SCH_SFQ
    scripts/config -e CONFIG_NET_SCH_TEQL
    scripts/config -e CONFIG_NET_SCH_TBF
    scripts/config -e CONFIG_NET_SCH_CBS
    scripts/config -e CONFIG_NET_SCH_ETF
    scripts/config -e CONFIG_NET_SCH_MQPRIO_LIB
    scripts/config -e CONFIG_NET_SCH_TAPRIO
    scripts/config -e CONFIG_NET_SCH_GRED
    scripts/config -e CONFIG_NET_SCH_NETEM
    scripts/config -e CONFIG_NET_SCH_DRR
    scripts/config -e CONFIG_NET_SCH_MQPRIO
    scripts/config -e CONFIG_NET_SCH_SKBPRIO
    scripts/config -e CONFIG_NET_SCH_CHOKE
    scripts/config -e CONFIG_NET_SCH_QFQ
    scripts/config -e CONFIG_NET_SCH_CODEL
    scripts/config -e CONFIG_NET_SCH_FQ_CODEL
    scripts/config -e CONFIG_NET_SCH_CAKE
    scripts/config -e CONFIG_NET_SCH_FQ
    scripts/config -e CONFIG_NET_SCH_HHF
    scripts/config -e CONFIG_NET_SCH_PIE
    scripts/config -e CONFIG_NET_SCH_FQ_PIE
    scripts/config -e CONFIG_NET_SCH_INGRESS
    scripts/config -e CONFIG_NET_SCH_PLUG
    scripts/config -e CONFIG_NET_SCH_ETS
    scripts/config -e CONFIG_NET_CLS_BASIC
    scripts/config -e CONFIG_NET_CLS_ROUTE4
    scripts/config -e CONFIG_NET_CLS_FW
    scripts/config -e CONFIG_NET_CLS_U32
    scripts/config -e CONFIG_NET_CLS_FLOW
    scripts/config -e CONFIG_NET_CLS_CGROUP
    scripts/config -e CONFIG_NET_CLS_BPF
    scripts/config -e CONFIG_NET_CLS_FLOWER
    scripts/config -e CONFIG_NET_CLS_MATCHALL
    scripts/config -e CONFIG_NET_EMATCH_CMP
    scripts/config -e CONFIG_NET_EMATCH_NBYTE
    scripts/config -e CONFIG_NET_EMATCH_U32
    scripts/config -e CONFIG_NET_EMATCH_META
    scripts/config -e CONFIG_NET_EMATCH_TEXT
    scripts/config -e CONFIG_NET_EMATCH_CANID
    scripts/config -e CONFIG_NET_EMATCH_IPSET
    scripts/config -e CONFIG_NET_EMATCH_IPT
    scripts/config -e CONFIG_NET_ACT_POLICE
    scripts/config -e CONFIG_NET_ACT_GACT
    scripts/config -e CONFIG_NET_ACT_MIRRED
    scripts/config -e CONFIG_NET_ACT_SAMPLE
    scripts/config -e CONFIG_NET_ACT_NAT
    scripts/config -e CONFIG_NET_ACT_PEDIT
    scripts/config -e CONFIG_NET_ACT_SIMP
    scripts/config -e CONFIG_NET_ACT_SKBEDIT
    scripts/config -e CONFIG_NET_ACT_CSUM
    scripts/config -e CONFIG_NET_ACT_MPLS
    scripts/config -e CONFIG_NET_ACT_VLAN
    scripts/config -e CONFIG_NET_ACT_BPF
    scripts/config -e CONFIG_NET_ACT_CONNMARK
    scripts/config -e CONFIG_NET_ACT_CTINFO
    scripts/config -e CONFIG_NET_ACT_SKBMOD
    scripts/config -e CONFIG_NET_ACT_IFE
    scripts/config -e CONFIG_NET_ACT_TUNNEL_KEY
    scripts/config -e CONFIG_NET_ACT_CT
    scripts/config -e CONFIG_NET_ACT_GATE
    scripts/config -e CONFIG_NET_IFE_SKBMARK
    scripts/config -e CONFIG_NET_IFE_SKBPRIO
    scripts/config -e CONFIG_NET_IFE_SKBTCINDEX
    scripts/config -e CONFIG_NET_MPLS_GSO
    scripts/config -e CONFIG_NET_NSH
    scripts/config -e CONFIG_NET_PKTGEN
    scripts/config -e CONFIG_NET_DROP_MONITOR
    scripts/config -e CONFIG_NET_9P
    scripts/config -e CONFIG_NET_9P_FD
    scripts/config -e CONFIG_NET_9P_VIRTIO
    scripts/config -e CONFIG_NET_9P_USBG
    scripts/config -e CONFIG_NET_9P_RDMA
    scripts/config -e CONFIG_NET_IFE
    scripts/config -e CONFIG_NET_SELFTESTS
    scripts/config -e CONFIG_NET_TEST
    scripts/config -e CONFIG_NET_TEAM
    scripts/config -e CONFIG_NET_TEAM_MODE_BROADCAST
    scripts/config -e CONFIG_NET_TEAM_MODE_ROUNDROBIN
    scripts/config -e CONFIG_NET_TEAM_MODE_RANDOM
    scripts/config -e CONFIG_NET_TEAM_MODE_ACTIVEBACKUP
    scripts/config -e CONFIG_NET_TEAM_MODE_LOADBALANCE
    scripts/config -e CONFIG_NET_VRF
    scripts/config -e CONFIG_NET_DSA_BCM_SF2
    scripts/config -e CONFIG_NET_DSA_LOOP
    scripts/config -e CONFIG_NET_DSA_HIRSCHMANN_HELLCREEK
    scripts/config -e CONFIG_NET_DSA_LANTIQ_GSWIP
    scripts/config -e CONFIG_NET_DSA_MT7530
    scripts/config -e CONFIG_NET_DSA_MT7530_MDIO
    scripts/config -e CONFIG_NET_DSA_MT7530_MMIO
    scripts/config -e CONFIG_NET_DSA_MV88E6060
    scripts/config -e CONFIG_NET_DSA_MICROCHIP_KSZ_COMMON
    scripts/config -e CONFIG_NET_DSA_MICROCHIP_KSZ9477_I2C
    scripts/config -e CONFIG_NET_DSA_MICROCHIP_KSZ_SPI
    scripts/config -e CONFIG_NET_DSA_MICROCHIP_KSZ8863_SMI
    scripts/config -e CONFIG_NET_DSA_MV88E6XXX
    scripts/config -e CONFIG_NET_DSA_MSCC_FELIX_DSA_LIB
    scripts/config -e CONFIG_NET_DSA_MSCC_OCELOT_EXT
    scripts/config -e CONFIG_NET_DSA_MSCC_FELIX
    scripts/config -e CONFIG_NET_DSA_MSCC_SEVILLE
    scripts/config -e CONFIG_NET_DSA_AR9331
    scripts/config -e CONFIG_NET_DSA_QCA8K
    scripts/config -e CONFIG_NET_DSA_SJA1105
    scripts/config -e CONFIG_NET_DSA_XRS700X
    scripts/config -e CONFIG_NET_DSA_XRS700X_I2C
    scripts/config -e CONFIG_NET_DSA_XRS700X_MDIO
    scripts/config -e CONFIG_NET_DSA_REALTEK
    scripts/config -e CONFIG_NET_DSA_REALTEK_RTL8365MB
    scripts/config -e CONFIG_NET_DSA_REALTEK_RTL8366RB
    scripts/config -e CONFIG_NET_DSA_SMSC_LAN9303
    scripts/config -e CONFIG_NET_DSA_SMSC_LAN9303_I2C
    scripts/config -e CONFIG_NET_DSA_SMSC_LAN9303_MDIO
    scripts/config -e CONFIG_NET_DSA_VITESSE_VSC73XX
    scripts/config -e CONFIG_NET_DSA_VITESSE_VSC73XX_SPI
    scripts/config -e CONFIG_NET_DSA_VITESSE_VSC73XX_PLATFORM
    scripts/config -e CONFIG_NET_XGENE
    scripts/config -e CONFIG_NET_XGENE_V2
    scripts/config -e CONFIG_NET_CALXEDA_XGMAC
    scripts/config -e CONFIG_NET_AIROHA
    scripts/config -e CONFIG_NET_MEDIATEK_SOC
    scripts/config -e CONFIG_NET_MEDIATEK_STAR_EMAC
    scripts/config -e CONFIG_NET_FAILOVER
    scripts/config -e CONFIG_NETCONSOLE
    scripts/config -e CONFIG_NETDEV_ADDR_LIST_TEST
    scripts/config -e CONFIG_NETDEV_NOTIFIER_ERROR_INJECT
    scripts/config -e CONFIG_NETDEVSIM
    scripts/config -e CONFIG_NETFILTER_NETLINK
    scripts/config -e CONFIG_NETFILTER_NETLINK_HOOK
    scripts/config -e CONFIG_NETFILTER_NETLINK_ACCT
    scripts/config -e CONFIG_NETFILTER_NETLINK_QUEUE
    scripts/config -e CONFIG_NETFILTER_NETLINK_LOG
    scripts/config -e CONFIG_NETFILTER_NETLINK_OSF
    scripts/config -e CONFIG_NETFILTER_CONNCOUNT
    scripts/config -e CONFIG_NETFILTER_SYNPROXY
    scripts/config -e CONFIG_NETFILTER_XTABLES
    scripts/config -e CONFIG_NETFILTER_XT_MARK
    scripts/config -e CONFIG_NETFILTER_XT_CONNMARK
    scripts/config -e CONFIG_NETFILTER_XT_SET
    scripts/config -e CONFIG_NETFILTER_XT_TARGET_AUDIT
    scripts/config -e CONFIG_NETFILTER_XT_TARGET_CHECKSUM
    scripts/config -e CONFIG_NETFILTER_XT_TARGET_CLASSIFY
    scripts/config -e CONFIG_NETFILTER_XT_TARGET_CONNMARK
    scripts/config -e CONFIG_NETFILTER_XT_TARGET_CONNSECMARK
    scripts/config -e CONFIG_NETFILTER_XT_TARGET_CT
    scripts/config -e CONFIG_NETFILTER_XT_TARGET_DSCP
    scripts/config -e CONFIG_NETFILTER_XT_TARGET_HL
    scripts/config -e CONFIG_NETFILTER_XT_TARGET_HMARK
    scripts/config -e CONFIG_NETFILTER_XT_TARGET_IDLETIMER
    scripts/config -e CONFIG_NETFILTER_XT_TARGET_LED
    scripts/config -e CONFIG_NETFILTER_XT_TARGET_LOG
    scripts/config -e CONFIG_NETFILTER_XT_TARGET_MARK
    scripts/config -e CONFIG_NETFILTER_XT_TARGET_NAT
    scripts/config -e CONFIG_NETFILTER_XT_TARGET_NETMAP
    scripts/config -e CONFIG_NETFILTER_XT_TARGET_NFLOG
    scripts/config -e CONFIG_NETFILTER_XT_TARGET_NFQUEUE
    scripts/config -e CONFIG_NETFILTER_XT_TARGET_NOTRACK
    scripts/config -e CONFIG_NETFILTER_XT_TARGET_RATEEST
    scripts/config -e CONFIG_NETFILTER_XT_TARGET_REDIRECT
    scripts/config -e CONFIG_NETFILTER_XT_TARGET_MASQUERADE
    scripts/config -e CONFIG_NETFILTER_XT_TARGET_TEE
    scripts/config -e CONFIG_NETFILTER_XT_TARGET_TPROXY
    scripts/config -e CONFIG_NETFILTER_XT_TARGET_TRACE
    scripts/config -e CONFIG_NETFILTER_XT_TARGET_SECMARK
    scripts/config -e CONFIG_NETFILTER_XT_TARGET_TCPMSS
    scripts/config -e CONFIG_NETFILTER_XT_TARGET_TCPOPTSTRIP
    scripts/config -e CONFIG_NETFILTER_XT_MATCH_ADDRTYPE
    scripts/config -e CONFIG_NETFILTER_XT_MATCH_BPF
    scripts/config -e CONFIG_NETFILTER_XT_MATCH_CGROUP
    scripts/config -e CONFIG_NETFILTER_XT_MATCH_CLUSTER
    scripts/config -e CONFIG_NETFILTER_XT_MATCH_COMMENT
    scripts/config -e CONFIG_NETFILTER_XT_MATCH_CONNBYTES
    scripts/config -e CONFIG_NETFILTER_XT_MATCH_CONNLABEL
    scripts/config -e CONFIG_NETFILTER_XT_MATCH_CONNLIMIT
    scripts/config -e CONFIG_NETFILTER_XT_MATCH_CONNMARK
    scripts/config -e CONFIG_NETFILTER_XT_MATCH_CONNTRACK
    scripts/config -e CONFIG_NETFILTER_XT_MATCH_CPU
    scripts/config -e CONFIG_NETFILTER_XT_MATCH_DCCP
    scripts/config -e CONFIG_NETFILTER_XT_MATCH_DEVGROUP
    scripts/config -e CONFIG_NETFILTER_XT_MATCH_DSCP
    scripts/config -e CONFIG_NETFILTER_XT_MATCH_ECN
    scripts/config -e CONFIG_NETFILTER_XT_MATCH_ESP
    scripts/config -e CONFIG_NETFILTER_XT_MATCH_HASHLIMIT
    scripts/config -e CONFIG_NETFILTER_XT_MATCH_HELPER
    scripts/config -e CONFIG_NETFILTER_XT_MATCH_HL
    scripts/config -e CONFIG_NETFILTER_XT_MATCH_IPCOMP
    scripts/config -e CONFIG_NETFILTER_XT_MATCH_IPRANGE
    scripts/config -e CONFIG_NETFILTER_XT_MATCH_IPVS
    scripts/config -e CONFIG_NETFILTER_XT_MATCH_L2TP
    scripts/config -e CONFIG_NETFILTER_XT_MATCH_LENGTH
    scripts/config -e CONFIG_NETFILTER_XT_MATCH_LIMIT
    scripts/config -e CONFIG_NETFILTER_XT_MATCH_MAC
    scripts/config -e CONFIG_NETFILTER_XT_MATCH_MARK
    scripts/config -e CONFIG_NETFILTER_XT_MATCH_MULTIPORT
    scripts/config -e CONFIG_NETFILTER_XT_MATCH_NFACCT
    scripts/config -e CONFIG_NETFILTER_XT_MATCH_OSF
    scripts/config -e CONFIG_NETFILTER_XT_MATCH_OWNER
    scripts/config -e CONFIG_NETFILTER_XT_MATCH_POLICY
    scripts/config -e CONFIG_NETFILTER_XT_MATCH_PHYSDEV
    scripts/config -e CONFIG_NETFILTER_XT_MATCH_PKTTYPE
    scripts/config -e CONFIG_NETFILTER_XT_MATCH_QUOTA
    scripts/config -e CONFIG_NETFILTER_XT_MATCH_RATEEST
    scripts/config -e CONFIG_NETFILTER_XT_MATCH_REALM
    scripts/config -e CONFIG_NETFILTER_XT_MATCH_RECENT
    scripts/config -e CONFIG_NETFILTER_XT_MATCH_SCTP
    scripts/config -e CONFIG_NETFILTER_XT_MATCH_SOCKET
    scripts/config -e CONFIG_NETFILTER_XT_MATCH_STATE
    scripts/config -e CONFIG_NETFILTER_XT_MATCH_STATISTIC
    scripts/config -e CONFIG_NETFILTER_XT_MATCH_STRING
    scripts/config -e CONFIG_NETFILTER_XT_MATCH_TCPMSS
    scripts/config -e CONFIG_NETFILTER_XT_MATCH_TIME
    scripts/config -e CONFIG_NETFILTER_XT_MATCH_U32
    scripts/config -e CONFIG_NETFS_SUPPORT
    scripts/config -e CONFIG_NETLINK_DIAG
    scripts/config -e CONFIG_NETROM
    scripts/config -e CONFIG_NF_CONNTRACK
    scripts/config -e CONFIG_NF_LOG_SYSLOG
    scripts/config -e CONFIG_NF_CONNTRACK_AMANDA
    scripts/config -e CONFIG_NF_CONNTRACK_FTP
    scripts/config -e CONFIG_NF_CONNTRACK_H323
    scripts/config -e CONFIG_NF_CONNTRACK_IRC
    scripts/config -e CONFIG_NF_CONNTRACK_BROADCAST
    scripts/config -e CONFIG_NF_CONNTRACK_NETBIOS_NS
    scripts/config -e CONFIG_NF_CONNTRACK_SNMP
    scripts/config -e CONFIG_NF_CONNTRACK_PPTP
    scripts/config -e CONFIG_NF_CONNTRACK_SANE
    scripts/config -e CONFIG_NF_CONNTRACK_SIP
    scripts/config -e CONFIG_NF_CONNTRACK_TFTP
    scripts/config -e CONFIG_NF_CT_NETLINK
    scripts/config -e CONFIG_NF_CT_NETLINK_TIMEOUT
    scripts/config -e CONFIG_NF_CT_NETLINK_HELPER
    scripts/config -e CONFIG_NF_NAT
    scripts/config -e CONFIG_NF_NAT_AMANDA
    scripts/config -e CONFIG_NF_NAT_FTP
    scripts/config -e CONFIG_NF_NAT_IRC
    scripts/config -e CONFIG_NF_NAT_SIP
    scripts/config -e CONFIG_NF_NAT_TFTP
    scripts/config -e CONFIG_NF_TABLES
    scripts/config -e CONFIG_NF_DUP_NETDEV
    scripts/config -e CONFIG_NF_FLOW_TABLE_INET
    scripts/config -e CONFIG_NF_FLOW_TABLE
    scripts/config -e CONFIG_NF_DEFRAG_IPV4
    scripts/config -e CONFIG_NF_SOCKET_IPV4
    scripts/config -e CONFIG_NF_TPROXY_IPV4
    scripts/config -e CONFIG_NF_DUP_IPV4
    scripts/config -e CONFIG_NF_LOG_ARP
    scripts/config -e CONFIG_NF_LOG_IPV4
    scripts/config -e CONFIG_NF_REJECT_IPV4
    scripts/config -e CONFIG_NF_NAT_SNMP_BASIC
    scripts/config -e CONFIG_NF_NAT_PPTP
    scripts/config -e CONFIG_NF_NAT_H323
    scripts/config -e CONFIG_NF_SOCKET_IPV6
    scripts/config -e CONFIG_NF_TPROXY_IPV6
    scripts/config -e CONFIG_NF_DUP_IPV6
    scripts/config -e CONFIG_NF_REJECT_IPV6
    scripts/config -e CONFIG_NF_LOG_IPV6
    scripts/config -e CONFIG_NF_DEFRAG_IPV6
    scripts/config -e CONFIG_NF_TABLES_BRIDGE
    scripts/config -e CONFIG_NF_CONNTRACK_BRIDGE
    scripts/config -e CONFIG_NFT_NUMGEN
    scripts/config -e CONFIG_NFT_CT
    scripts/config -e CONFIG_NFT_FLOW_OFFLOAD
    scripts/config -e CONFIG_NFT_LOG
    scripts/config -e CONFIG_NFT_LIMIT
    scripts/config -e CONFIG_NFT_MASQ
    scripts/config -e CONFIG_NFT_REDIR
    scripts/config -e CONFIG_NFT_TUNNEL
    scripts/config -e CONFIG_NFT_QUOTA
    scripts/config -e CONFIG_NFT_COMPAT
    scripts/config -e CONFIG_NFT_HASH
    scripts/config -e CONFIG_NFT_XFRM
    scripts/config -e CONFIG_NFT_SOCKET
    scripts/config -e CONFIG_NFT_TPROXY
    scripts/config -e CONFIG_NFT_BRIDGE_META
    scripts/config -e CONFIG_NFT_BRIDGE_REJECT
    scripts/config -e CONFIG_INET_AH
    scripts/config -e CONFIG_INET_ESP
    scripts/config -e CONFIG_INET_ESP_OFFLOAD
    scripts/config -e CONFIG_INET_IPCOMP
    scripts/config -e CONFIG_INET_XFRM_TUNNEL
    scripts/config -e CONFIG_INET_TUNNEL
    scripts/config -e CONFIG_INET_DIAG
    scripts/config -e CONFIG_INET_TCP_DIAG
    scripts/config -e CONFIG_INET_UDP_DIAG
    scripts/config -e CONFIG_INET_RAW_DIAG
    scripts/config -e CONFIG_INET_MPTCP_DIAG
    scripts/config -e CONFIG_INET_DCCP_DIAG
    scripts/config -e CONFIG_INET_SCTP_DIAG
    scripts/config -e CONFIG_INET6_AH
    scripts/config -e CONFIG_INET6_ESP
    scripts/config -e CONFIG_INET6_ESP_OFFLOAD
    scripts/config -e CONFIG_INET6_IPCOMP
    scripts/config -e CONFIG_INET6_XFRM_TUNNEL
    scripts/config -e CONFIG_INET6_TUNNEL
    scripts/config -e CONFIG_IP_MULTICAST
    scripts/config -e CONFIG_IP_ADVANCED_ROUTER
    scripts/config -e CONFIG_IP_FIB_TRIE_STATS
    scripts/config -e CONFIG_IP_MULTIPLE_TABLES
    scripts/config -e CONFIG_IP_ROUTE_MULTIPATH
    scripts/config -e CONFIG_IP_ROUTE_VERBOSE
    scripts/config -e CONFIG_IP_ROUTE_CLASSID
    scripts/config -e CONFIG_IP_PNP
    scripts/config -e CONFIG_IP_PNP_DHCP
    scripts/config -e CONFIG_IP_PNP_BOOTP
    scripts/config -e CONFIG_IP_PNP_RARP
    scripts/config -e CONFIG_IP_MROUTE_COMMON
    scripts/config -e CONFIG_IP_MROUTE
    scripts/config -e CONFIG_IP_MROUTE_MULTIPLE_TABLES
    scripts/config -e CONFIG_IP_PIMSM_V1
    scripts/config -e CONFIG_IP_PIMSM_V2
    scripts/config -e CONFIG_IP_SET
    scripts/config --set-val CONFIG_IP_SET_MAX 256
    scripts/config -e CONFIG_IP_SET_BITMAP_IP
    scripts/config -e CONFIG_IP_SET_BITMAP_IPMAC
    scripts/config -e CONFIG_IP_SET_BITMAP_PORT
    scripts/config -e CONFIG_IP_SET_HASH_IP
    scripts/config -e CONFIG_IP_SET_HASH_IPMARK
    scripts/config -e CONFIG_IP_SET_HASH_IPPORT
    scripts/config -e CONFIG_IP_SET_HASH_IPPORTIP
    scripts/config -e CONFIG_IP_SET_HASH_IPPORTNET
    scripts/config -e CONFIG_IP_SET_HASH_IPMAC
    scripts/config -e CONFIG_IP_SET_HASH_MAC
    scripts/config -e CONFIG_IP_SET_HASH_NETPORTNET
    scripts/config -e CONFIG_IP_SET_HASH_NET
    scripts/config -e CONFIG_IP_SET_HASH_NETNET
    scripts/config -e CONFIG_IP_SET_HASH_NETPORT
    scripts/config -e CONFIG_IP_SET_HASH_NETIFACE
    scripts/config -e CONFIG_IP_SET_LIST_SET
    scripts/config -e CONFIG_IP_VS
    scripts/config -e CONFIG_IP_VS_IPV6
    scripts/config -e CONFIG_IP_VS_DEBUG
    scripts/config --set-val CONFIG_IP_VS_TAB_BITS 12
    scripts/config -e CONFIG_IP_VS_PROTO_TCP
    scripts/config -e CONFIG_IP_VS_PROTO_UDP
    scripts/config -e CONFIG_IP_VS_PROTO_AH_ESP
    scripts/config -e CONFIG_IP_VS_PROTO_ESP
    scripts/config -e CONFIG_IP_VS_PROTO_AH
    scripts/config -e CONFIG_IP_VS_PROTO_SCTP
    scripts/config -e CONFIG_IP_VS_RR
    scripts/config -e CONFIG_IP_VS_WRR
    scripts/config -e CONFIG_IP_VS_LC
    scripts/config -e CONFIG_IP_VS_WLC
    scripts/config -e CONFIG_IP_VS_FO
    scripts/config -e CONFIG_IP_VS_OVF
    scripts/config -e CONFIG_IP_VS_LBLC
    scripts/config -e CONFIG_IP_VS_LBLCR
    scripts/config -e CONFIG_IP_VS_DH
    scripts/config -e CONFIG_IP_VS_SH
    scripts/config -e CONFIG_IP_VS_MH
    scripts/config -e CONFIG_IP_VS_SED
    scripts/config -e CONFIG_IP_VS_NQ
    scripts/config -e CONFIG_IP_VS_TWOS
    scripts/config --set-val CONFIG_IP_VS_SH_TAB_BITS 8
    scripts/config --set-val CONFIG_IP_VS_MH_TAB_INDEX 12
    scripts/config -e CONFIG_IP_VS_FTP
    scripts/config -e CONFIG_IP_VS_NFCT
    scripts/config -e CONFIG_IP_VS_PE_SIP
    scripts/config -e CONFIG_IP_NF_IPTABLES
    scripts/config -e CONFIG_IP_NF_MATCH_AH
    scripts/config -e CONFIG_IP_NF_MATCH_ECN
    scripts/config -e CONFIG_IP_NF_MATCH_RPFILTER
    scripts/config -e CONFIG_IP_NF_MATCH_TTL
    scripts/config -e CONFIG_IP_NF_FILTER
    scripts/config -e CONFIG_IP_NF_TARGET_REJECT
    scripts/config -e CONFIG_IP_NF_TARGET_SYNPROXY
    scripts/config -e CONFIG_IP_NF_NAT
    scripts/config -e CONFIG_IP_NF_TARGET_MASQUERADE
    scripts/config -e CONFIG_IP_NF_TARGET_NETMAP
    scripts/config -e CONFIG_IP_NF_TARGET_REDIRECT
    scripts/config -e CONFIG_IP_NF_MANGLE
    scripts/config -e CONFIG_IP_NF_TARGET_ECN
    scripts/config -e CONFIG_IP_NF_TARGET_TTL
    scripts/config -e CONFIG_IP_NF_RAW
    scripts/config -e CONFIG_IP_NF_SECURITY
    scripts/config -e CONFIG_IP_NF_ARPTABLES
    scripts/config -e CONFIG_IP_NF_ARPFILTER
    scripts/config -e CONFIG_IP_NF_ARP_MANGLE
    scripts/config -e CONFIG_IP_DCCP
    scripts/config -e CONFIG_IP_DCCP_CCID2_DEBUG
    scripts/config -e CONFIG_IP_DCCP_CCID3
    scripts/config -e CONFIG_IP_DCCP_CCID3_DEBUG
    scripts/config -e CONFIG_IP_DCCP_TFRC_LIB
    scripts/config -e CONFIG_IP_DCCP_TFRC_DEBUG
    scripts/config -e CONFIG_IP_DCCP_DEBUG
    scripts/config -e CONFIG_IP_SCTP
    scripts/config -e CONFIG_IP6_NF_IPTABLES
    scripts/config -e CONFIG_IP6_NF_MATCH_AH
    scripts/config -e CONFIG_IP6_NF_MATCH_EUI64
    scripts/config -e CONFIG_IP6_NF_MATCH_FRAG
    scripts/config -e CONFIG_IP6_NF_MATCH_OPTS
    scripts/config -e CONFIG_IP6_NF_MATCH_HL
    scripts/config -e CONFIG_IP6_NF_MATCH_IPV6HEADER
    scripts/config -e CONFIG_IP6_NF_MATCH_MH
    scripts/config -e CONFIG_IP6_NF_MATCH_RPFILTER
    scripts/config -e CONFIG_IP6_NF_MATCH_RT
    scripts/config -e CONFIG_IP6_NF_MATCH_SRH
    scripts/config -e CONFIG_IP6_NF_TARGET_HL
    scripts/config -e CONFIG_IP6_NF_FILTER
    scripts/config -e CONFIG_IP6_NF_TARGET_REJECT
    scripts/config -e CONFIG_IP6_NF_TARGET_SYNPROXY
    scripts/config -e CONFIG_IP6_NF_MANGLE
    scripts/config -e CONFIG_IP6_NF_RAW
    scripts/config -e CONFIG_IP6_NF_SECURITY
    scripts/config -e CONFIG_IP6_NF_NAT
    scripts/config -e CONFIG_IP6_NF_TARGET_MASQUERADE
    scripts/config -e CONFIG_IP6_NF_TARGET_NPT
    scripts/config -e CONFIG_IPV6
    scripts/config -e CONFIG_IPV6_ROUTER_PREF
    scripts/config -e CONFIG_IPV6_ROUTE_INFO
    scripts/config -e CONFIG_IPV6_OPTIMISTIC_DAD
    scripts/config -e CONFIG_IPV6_MIP6
    scripts/config -e CONFIG_IPV6_ILA
    scripts/config -e CONFIG_IPV6_VTI
    scripts/config -e CONFIG_IPV6_SIT
    scripts/config -e CONFIG_IPV6_SIT_6RD
    scripts/config -e CONFIG_IPV6_NDISC_NODETYPE
    scripts/config -e CONFIG_IPV6_TUNNEL
    scripts/config -e CONFIG_IPV6_GRE
    scripts/config -e CONFIG_IPV6_FOU
    scripts/config -e CONFIG_IPV6_FOU_TUNNEL
    scripts/config -e CONFIG_IPV6_MULTIPLE_TABLES
    scripts/config -e CONFIG_IPV6_SUBTREES
    scripts/config -e CONFIG_IPV6_MROUTE
    scripts/config -e CONFIG_IPV6_MROUTE_MULTIPLE_TABLES
    scripts/config -e CONFIG_IPV6_PIMSM_V2
    scripts/config -e CONFIG_IPV6_SEG6_LWTUNNEL
    scripts/config -e CONFIG_IPV6_SEG6_HMAC
    scripts/config -e CONFIG_IPV6_RPL_LWTUNNEL
    scripts/config -e CONFIG_IPV6_IOAM6_LWTUNNEL
    scripts/config -e CONFIG_IPVLAN
    scripts/config -e CONFIG_IPVTAP
    scripts/config -e CONFIG_VLAN_8021Q
    scripts/config -e CONFIG_VLAN_8021Q_GVRP
    scripts/config -e CONFIG_VLAN_8021Q_MVRP
    scripts/config -e CONFIG_VETH
    scripts/config -e CONFIG_TUN
    scripts/config -e CONFIG_TUN_VNET_CROSS_LE
    scripts/config -e CONFIG_TAP
    scripts/config -e CONFIG_XFRM
    scripts/config -e CONFIG_XFRM_OFFLOAD
    scripts/config -e CONFIG_XFRM_ALGO
    scripts/config -e CONFIG_XFRM_USER
    scripts/config -e CONFIG_XFRM_USER_COMPAT
    scripts/config -e CONFIG_XFRM_INTERFACE
    scripts/config -e CONFIG_XFRM_SUB_POLICY
    scripts/config -e CONFIG_XFRM_MIGRATE
    scripts/config -e CONFIG_XFRM_STATISTICS
    scripts/config -e CONFIG_XFRM_AH
    scripts/config -e CONFIG_XFRM_ESP
    scripts/config -e CONFIG_XFRM_IPCOMP
    scripts/config -e CONFIG_XFRM_IPTFS
    scripts/config -e CONFIG_XFRM_ESPINTCP
    scripts/config -e CONFIG_MPTCP
    scripts/config -e CONFIG_MPTCP_KUNIT_TEST
    scripts/config -e CONFIG_PPTP
    scripts/config -e CONFIG_PPPOE
    scripts/config -e CONFIG_PPPOE_HASH_BITS_4
    scripts/config --set-val CONFIG_PPPOE_HASH_BITS 4
    scripts/config -e CONFIG_PPP
    scripts/config -e CONFIG_PPP_BSDCOMP
    scripts/config -e CONFIG_PPP_DEFLATE
    scripts/config -e CONFIG_PPP_FILTER
    scripts/config -e CONFIG_PPP_MPPE
    scripts/config -e CONFIG_PPP_MULTILINK
    scripts/config -e CONFIG_PPP_ASYNC
    scripts/config -e CONFIG_PPP_SYNC_TTY
    scripts/config -e CONFIG_GENEVE
    scripts/config -e CONFIG_L2TP
    scripts/config -e CONFIG_L2TP_DEBUGFS
    scripts/config -e CONFIG_L2TP_V3
    scripts/config -e CONFIG_L2TP_IP
    scripts/config -e CONFIG_L2TP_ETH
    scripts/config -e CONFIG_VXLAN
    scripts/config -e CONFIG_BRIDGE_NETFILTER
    scripts/config -e CONFIG_BRIDGE_NF_EBTABLES
    scripts/config -e CONFIG_BRIDGE_EBT_BROUTE
    scripts/config -e CONFIG_BRIDGE_EBT_T_FILTER
    scripts/config -e CONFIG_BRIDGE_EBT_T_NAT
    scripts/config -e CONFIG_BRIDGE_EBT_802_3
    scripts/config -e CONFIG_BRIDGE_EBT_AMONG
    scripts/config -e CONFIG_BRIDGE_EBT_ARP
    scripts/config -e CONFIG_BRIDGE_EBT_IP
    scripts/config -e CONFIG_BRIDGE_EBT_IP6
    scripts/config -e CONFIG_BRIDGE_EBT_LIMIT
    scripts/config -e CONFIG_BRIDGE_EBT_MARK
    scripts/config -e CONFIG_BRIDGE_EBT_PKTTYPE
    scripts/config -e CONFIG_BRIDGE_EBT_STP
    scripts/config -e CONFIG_BRIDGE_EBT_VLAN
    scripts/config -e CONFIG_BRIDGE_EBT_ARPREPLY
    scripts/config -e CONFIG_BRIDGE_EBT_DNAT
    scripts/config -e CONFIG_BRIDGE_EBT_MARK_T
    scripts/config -e CONFIG_BRIDGE_EBT_REDIRECT
    scripts/config -e CONFIG_BRIDGE_EBT_SNAT
    scripts/config -e CONFIG_BRIDGE_EBT_LOG
    scripts/config -e CONFIG_BRIDGE_EBT_NFLOG
    scripts/config -e CONFIG_BRIDGE
    scripts/config -e CONFIG_BRIDGE_IGMP_SNOOPING
    scripts/config -e CONFIG_BRIDGE_VLAN_FILTERING
    scripts/config -e CONFIG_BRIDGE_MRP
    scripts/config -e CONFIG_BRIDGE_CFM
    scripts/config -e CONFIG_CGROUP_FAVOR_DYNMODS
    scripts/config -e CONFIG_CGROUP_WRITEBACK
    scripts/config -e CONFIG_CGROUP_SCHED
    scripts/config -e CONFIG_CGROUP_PIDS
    scripts/config -e CONFIG_CGROUP_RDMA
    scripts/config -e CONFIG_CGROUP_DMEM
    scripts/config -e CONFIG_CGROUP_FREEZER
    scripts/config -e CONFIG_CGROUP_HUGETLB
    scripts/config -e CONFIG_CGROUP_DEVICE
    scripts/config -e CONFIG_CGROUP_CPUACCT
    scripts/config -e CONFIG_CGROUP_PERF
    scripts/config -e CONFIG_CGROUP_BPF
    scripts/config -e CONFIG_BPF_SYSCALL
    scripts/config -e CONFIG_BPF_JIT
    scripts/config -e CONFIG_BPF_JIT_ALWAYS_ON
    scripts/config -e CONFIG_CGROUP_MISC
    scripts/config -e CONFIG_CGROUP_DEBUG
    scripts/config -e CONFIG_CGROUP_NET_PRIO
    scripts/config -e CONFIG_CGROUP_NET_CLASSID
    scripts/config -e CONFIG_CGROUPS
    scripts/config -e CONFIG_BPF
    scripts/config -e CONFIG_LWTUNNEL
    scripts/config -e CONFIG_LWTUNNEL_BPF
    scripts/config -e CONFIG_WIREGUARD
    scripts/config -e CONFIG_MACVLAN
    scripts/config -e CONFIG_EQUALIZER
    scripts/config -e CONFIG_NET_FC
    scripts/config -e CONFIG_IFB
    scripts/config -e CONFIG_BAREUDP
    scripts/config -e CONFIG_GTP
    scripts/config -e CONFIG_PFCP
    scripts/config -e CONFIG_AMT
    scripts/config -e CONFIG_MACSEC
    scripts/config -e CONFIG_NETCONSOLE_EXTENDED_LOG
    scripts/config -e CONFIG_NLMON
    scripts/config -e CONFIG_NETKIT
    scripts/config -e CONFIG_ARCNET
    scripts/config -e CONFIG_MCTP
    scripts/config -e CONFIG_MCTP_FLOWS
    scripts/config -e CONFIG_MCTP_SERIAL
    scripts/config -e CONFIG_MCTP_TRANSPORT_I2C
    scripts/config -e CONFIG_MCTP_TRANSPORT_I3C
    scripts/config -e CONFIG_SCTP_DBG_OBJCNT
    scripts/config -e CONFIG_SCTP_DEFAULT_COOKIE_HMAC_MD5
    scripts/config -e CONFIG_SCTP_COOKIE_HMAC_MD5
    scripts/config -e CONFIG_SCTP_COOKIE_HMAC_SHA1
    scripts/config -e CONFIG_NFT_BRIDGE_META
    scripts/config -e CONFIG_NFT_BRIDGE_REJECT
    scripts/config -e CONFIG_NETFILTER_ADVANCED
    scripts/config -e CONFIG_NETFILTER_NETLINK_GLUE_CT
    scripts/config -e CONFIG_NETFILTER_XTABLES_COMPAT
    scripts/config -e CONFIG_ZRAM
    scripts/config -e CONFIG_RETPOLINE
    scripts/config -e CONFIG_PAGE_POISONING
    scripts/config -e CONFIG_GCC_PLUGIN_STACKLEAK
    scripts/config -e CONFIG_DM_CRYPT
    scripts/config -e CONFIG_ARCH_HAS_ELF_RANDOMIZE
    scripts/config -e CONFIG_INIT_ON_FREE_DEFAULT_ON
    scripts/config -e CONFIG_INIT_ON_ALLOC_DEFAULT_ON
    scripts/config -e CONFIG_DEBUG_VIRTUAL
    scripts/config -e CONFIG_INIT_STACK_ALL_ZERO
    scripts/config -e CONFIG_STACKPROTECTOR
    scripts/config -e CONFIG_STACKPROTECTOR_STRONG
    scripts/config -e CONFIG_STACKPROTECTOR_PER_TASK
    scripts/config -e CONFIG_VMAP_STACK
    scripts/config -e CONFIG_SCHED_STACK_END_CHECK
    scripts/config -e CONFIG_STACKLEAK_METRICS
    scripts/config -e CONFIG_STACKLEAK_RUNTIME_DISABLE
    scripts/config -e CONFIG_GCC_PLUGIN_STACKLEAK
    scripts/config -e CONFIG_STRICT_KERNEL_RWX
    scripts/config -e CONFIG_SLAB_FREELIST_HARDENED
    scripts/config -e CONFIG_SLAB_FREELIST_RANDOM
    scripts/config -e CONFIG_HARDENED_USERCOPY
    scripts/config -e CONFIG_HAVE_HARDENED_USERCOPY_ALLOCATOR
    scripts/config -e CONFIG_X86_UMIP
    scripts/config -e CONFIG_ARCH_HAS_ELF_RANDOMIZE
    scripts/config -e CONFIG_RANDOMIZE_BASE
    scripts/config -e CONFIG_RANDOMIZE_MEMORY
    scripts/config -e CONFIG_GCC_PLUGIN_RANDSTRUCT
    scripts/config -e CONFIG_SECCOMP
    scripts/config -e CONFIG_LEGACY_VSYSCALL_NONE
    scripts/config -e CONFIG_SECURITY
    scripts/config -e CONFIG_SECURITY_YAMA
    scripts/config -e CONFIG_SECURITY_LOCKDOWN_LSM
    scripts/config -e CONFIG_SECURITY_LOCKDOWN_LSM_EARLY
    scripts/config -e CONFIG_LOCK_DOWN_KERNEL_FORCE_CONFIDENTIALITY
    scripts/config -e CONFIG_SECURITY_SAFESETID
    scripts/config -e CONFIG_SECURITY_LOADPIN
    scripts/config -e CONFIG_SECURITY_LOADPIN_ENFORCE
    scripts/config -d CONFIG_HZ_250
    scripts/config -d CONFIG_HZ_300
    scripts/config -d CONFIG_HZ_1000
    scripts/config -d CONFIG_NO_HZ_IDLE
    scripts/config -d CONFIG_NO_HZ
    scripts/config -d CONFIG_HAVE_KERNEL_BZIP2
    scripts/config -d CONFIG_HAVE_KERNEL_LZMA
    scripts/config -d CONFIG_HAVE_KERNEL_XZ
    scripts/config -d CONFIG_HAVE_KERNEL_LZO
    scripts/config -d CONFIG_HAVE_KERNEL_LZ4
    scripts/config -d CONFIG_HAVE_KERNEL_ZSTD
    scripts/config -d CONFIG_KERNEL_BZIP2
    scripts/config -d CONFIG_KERNEL_LZMA
    scripts/config -d CONFIG_KERNEL_XZ
    scripts/config -d CONFIG_KERNEL_LZO
    scripts/config -d CONFIG_KERNEL_LZ4
    scripts/config -d CONFIG_KERNEL_ZSTD
    scripts/config -d CONFIG_DRM
    scripts/config -d CONFIG_VIDEO
    scripts/config -d CONFIG_HDMI
    scripts/config -d CONFIG_AGP
    scripts/config -d CONFIG_WLAN
    scripts/config -d CONFIG_HID
    scripts/config -d CONFIG_USB
    scripts/config -d CONFIG_I2C
    scripts/config -d CONFIG_PPS
    scripts/config -d CONFIG_YENTA
    scripts/config -d CONFIG_CARDBUS
    scripts/config -d CONFIG_POWER_SUPPLY
    scripts/config -d CONFIG_SOUND
    scripts/config -d CONFIG_SND
    scripts/config -d CONFIG_NET_VENDOR_3COM
    scripts/config -d CONFIG_NET_VENDOR_ADAPTEC
    scripts/config -d CONFIG_NET_VENDOR_AGERE
    scripts/config -d CONFIG_NET_VENDOR_ALACRITECH
    scripts/config -d CONFIG_NET_VENDOR_ALTEON
    scripts/config -d CONFIG_NET_VENDOR_AMAZON
    scripts/config -d CONFIG_NET_VENDOR_AMD
    scripts/config -d CONFIG_NET_VENDOR_AQUANTIA
    scripts/config -d CONFIG_NET_VENDOR_ARC
    scripts/config -d CONFIG_NET_VENDOR_ASIX
    scripts/config -d CONFIG_NET_VENDOR_ATHEROS
    scripts/config -d CONFIG_NET_VENDOR_BROADCOM
    scripts/config -d CONFIG_NET_VENDOR_CADENCE
    scripts/config -d CONFIG_NET_VENDOR_CAVIUM
    scripts/config -d CONFIG_NET_VENDOR_CHELSIO
    scripts/config -d CONFIG_NET_VENDOR_CISCO
    scripts/config -d CONFIG_NET_VENDOR_CORTINA
    scripts/config -d CONFIG_NET_VENDOR_DAVICOM
    scripts/config -d CONFIG_NET_VENDOR_DEC
    scripts/config -d CONFIG_NET_VENDOR_DLINK
    scripts/config -d CONFIG_NET_VENDOR_EMULEX
    scripts/config -d CONFIG_NET_VENDOR_ENGLEDER
    scripts/config -d CONFIG_NET_VENDOR_EZCHIP
    scripts/config -d CONFIG_NET_VENDOR_FUJITSU
    scripts/config -d CONFIG_NET_VENDOR_FUNGIBLE
    scripts/config -d CONFIG_NET_VENDOR_GOOGLE
    scripts/config -d CONFIG_NET_VENDOR_HISILICON
    scripts/config -d CONFIG_NET_VENDOR_HUAWEI
    scripts/config -d CONFIG_NET_VENDOR_I825XX
    scripts/config -d CONFIG_NET_VENDOR_INTEL
    scripts/config -d CONFIG_NET_VENDOR_LITEX
    scripts/config -d CONFIG_NET_VENDOR_MARVELL
    scripts/config -d CONFIG_NET_VENDOR_MELLANOX
    scripts/config -d CONFIG_NET_VENDOR_META
    scripts/config -d CONFIG_NET_VENDOR_MICREL
    scripts/config -d CONFIG_NET_VENDOR_MICROCHIP
    scripts/config -d CONFIG_NET_VENDOR_MICROSEMI
    scripts/config -d CONFIG_NET_VENDOR_MICROSOFT
    scripts/config -d CONFIG_NET_VENDOR_MYRI
    scripts/config -d CONFIG_NET_VENDOR_NI
    scripts/config -d CONFIG_NET_VENDOR_NATSEMI
    scripts/config -d CONFIG_NET_VENDOR_NETERION
    scripts/config -d CONFIG_NET_VENDOR_NETRONOME
    scripts/config -d CONFIG_NET_VENDOR_8390
    scripts/config -d CONFIG_NET_VENDOR_NVIDIA
    scripts/config -d CONFIG_NET_VENDOR_OKI
    scripts/config -d CONFIG_NET_VENDOR_PACKET_ENGINES
    scripts/config -d CONFIG_NET_VENDOR_PENSANDO
    scripts/config -d CONFIG_NET_VENDOR_QLOGIC
    scripts/config -d CONFIG_NET_VENDOR_BROCADE
    scripts/config -d CONFIG_NET_VENDOR_QUALCOMM
    scripts/config -d CONFIG_NET_VENDOR_RDC
    scripts/config -d CONFIG_NET_VENDOR_REALTEK
    scripts/config -d CONFIG_NET_VENDOR_RENESAS
    scripts/config -d CONFIG_NET_VENDOR_ROCKER
    scripts/config -d CONFIG_NET_VENDOR_SAMSUNG
    scripts/config -d CONFIG_NET_VENDOR_SEEQ
    scripts/config -d CONFIG_NET_VENDOR_SILAN
    scripts/config -d CONFIG_NET_VENDOR_SIS
    scripts/config -d CONFIG_NET_VENDOR_SOLARFLARE
    scripts/config -d CONFIG_NET_VENDOR_SMSC
    scripts/config -d CONFIG_NET_VENDOR_SOCIONEXT
    scripts/config -d CONFIG_NET_VENDOR_STMICRO
    scripts/config -d CONFIG_NET_VENDOR_SUN
    scripts/config -d CONFIG_NET_VENDOR_SYNOPSYS
    scripts/config -d CONFIG_NET_VENDOR_TEHUTI
    scripts/config -d CONFIG_NET_VENDOR_TI
    scripts/config -d CONFIG_NET_VENDOR_VERTEXCOM
    scripts/config -d CONFIG_NET_VENDOR_VIA
    scripts/config -d CONFIG_NET_VENDOR_WANGXUN
    scripts/config -d CONFIG_NET_VENDOR_WIZNET
    scripts/config -d CONFIG_NET_VENDOR_XILINX
    scripts/config -d CONFIG_NET_VENDOR_XIRCOM
    scripts/config -d CONFIG_INPUT
    scripts/config -d CONFIG_USB_USBNET
    scripts/config -d CONFIG_DEVMEM
    scripts/config -d CONFIG_DEBUG_BUGVERBOSE
    scripts/config -d COMPAT_BRK
    scripts/config -d CONFIG_INET_DIAG
    scripts/config -d CONFIG_HARDENED_USERCOPY_FALLBACK
    scripts/config -d CONFIG_HARDENED_USERCOPY_PAGESPAN
    scripts/config -d CONFIG_PROC_PAGE_MONITOR
    scripts/config -d CONFIG_PROC_VMCORE
    scripts/config -d CONFIG_DEBUG_FS
    scripts/config -d CONFIG_HIBERNATION
    scripts/config -d CONFIG_KEXEC
    scripts/config -d CONFIG_KEXEC_FILE
    scripts/config -d CONFIG_USELIB
    scripts/config -d CONFIG_MODULES
    scripts/config -d CONFIG_MODIFY_LDT_SYSCALL
    scripts/config -d CONFIG_X86_VSYSCALL_EMULATION
    scripts/config -d CONFIG_SECURITY_WRITABLE_HOOKS
    scripts/config -d CONFIG_SECURITY_SELINUX_DISABLE

    make -j$(nproc) bzImage
    make -j$(nproc) modules
fi

make headers_install && make modules_install

mkdir -p /boot/efi/efi/boot
cp arch/x86_64/boot/bzImage /boot/efi/efi/boot/vmlinuz

# Create startup.nsh for EFI boot
cat << 'EOFNSH' > /boot/efi/efi/boot/startup.nsh
fs0:\efi\boot\vmlinuz console=ttyS0 root=/dev/vda2 rootflags=ufstype=ufs2 rootfstype=ufs
EOFNSH
chmod +x /boot/efi/efi/boot/startup.nsh

# Basic system configuration
echo "${VM_NAME}" > /etc/hostname
ln -s /etc/sv/agetty-ttyS0 /etc/runit/runsvdir/default

# Install sudo
xbps-install -y sudo

# Create a user with sudo permissions
useradd -m -G wheel -s /bin/bash admin
usermod -U admin
passwd -d admin

# Add the user to sudoers with ALL/ALL privileges
echo "admin ALL=(ALL) ALL" > /etc/sudoers.d/admin
chmod 440 /etc/sudoers.d/admin

# Set up SSH keys for admin user
mkdir -p /home/admin/.ssh
mv /root/.ssh/authorized_keys /home/admin/.ssh/
chown -R admin:admin /home/admin/.ssh
chmod 700 /home/admin/.ssh
chmod 600 /home/admin/.ssh/authorized_keys

EOF

# Make the script executable
chmod +x ${VOID_INSTALL_DIR}/setup.sh || { echo "Failed to make setup script executable"; exit 1; }

# Check if Linux source exists in ${DIST_DIR}, if not clone it
if [ ! -d "${DIST_DIR}/linux" ]; then
    mkdir -p ${DIST_DIR} || { echo "Failed to create ${DIST_DIR} directory"; exit 1; }
    git clone --single-branch --branch "${LINUX_KERNEL_BRANCH}" https://github.com/torvalds/linux.git ${DIST_DIR}/linux || { echo "Failed to clone Linux source"; exit 1; }
fi

# Mount Linux source to VM using nullfs instead of copying
mkdir -p ${VOID_INSTALL_DIR}/usr/src/linux || { echo "Failed to create Linux source mount point"; exit 1; }
mount_nullfs ${DIST_DIR}/linux ${VOID_INSTALL_DIR}/usr/src/linux || { echo "Failed to mount Linux source"; exit 1; }

# Run the script inside chroot and ensure we exit properly
cd /vm || { echo "Failed to change to /vm directory"; exit 1; }
chroot ${VOID_INSTALL_DIR} /setup.sh || { echo "Failed to run setup script in chroot"; exit 1; }

# Remove repo IP from hosts file
if [ -n "$REPO_IP" ]; then
    echo "Removing repo IP from hosts file..."
    grep -v "^$REPO_IP repo-default.voidlinux.org" /etc/hosts > /tmp/hosts.tmp
    cat /tmp/hosts.tmp > /etc/hosts
    rm /tmp/hosts.tmp
fi

# Configure tap interface if specified
if [ -n "$TAP_INTERFACE" ]; then
    echo "Configuring VM to use network interface: ${TAP_INTERFACE}"
    echo "network0_device=\"${TAP_INTERFACE}\"" >> ${VM_DIR}/${VM_NAME}/${VM_NAME}.conf || { echo "Failed to update VM network configuration"; exit 1; }
fi

echo "Installation complete for VM '${VM_NAME}' with template '${VM_TEMPLATE}'."
echo "Start the VM with: vm start -f ${VM_NAME}"
