#!/usr/bin/env bash

set -e

# Configuration variables
VM_DIR="/vm"
STORAGE_POOL="storage"
DIST_DIR="/mnt/dist"
FREEBSD_INSTALL_DIR="/mnt/freebsd-install"

# Function to handle cleanup on exit
cleanup() {
    local exit_code=$?
    echo "Cleaning up..."

    # First try to exit chroot if we're in it
    if [ "$(pwd)" = "$FREEBSD_INSTALL_DIR" ]; then
        cd /vm || cd /
    fi

    # Wait a moment for any processes to finish
    sleep 1

    # Unmount in reverse order of mounting, with retries
    for mount_point in "$FREEBSD_INSTALL_DIR/dev" \
                      "$FREEBSD_INSTALL_DIR/boot/efi" \
                      "$FREEBSD_INSTALL_DIR"; do
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
VM_TEMPLATE="freebsd" # Default template
TAP_INTERFACE="" # Default empty tap interface
FREEBSD_VERSION="15.1" # Default FreeBSD version

usage() {
    echo "Usage: $0 <vm_name> [options]"
    echo "Options:"
    echo "  -t, --template <template>   Specify the VM template to use (default: freebsd)"
    echo "  -i, --interface <tap>       Specify the tap interface to use (e.g. tap3)"
    echo "  -v, --version <version>     Specify the FreeBSD version (default: 15.1)"
    echo "  -h, --help                  Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 my-vm                    # Create VM 'my-vm' with default 'freebsd' template"
    echo "  $0 my-vm -t custom          # Create VM 'my-vm' with 'custom' template"
    echo "  $0 my-vm -i tap3            # Create VM 'my-vm' using tap3 network interface"
    echo "  $0 my-vm -v 14.0            # Create VM 'my-vm' with FreeBSD 14.0"
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
        -v|--version)
            FREEBSD_VERSION="$2"
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

echo "Creating VM with name: ${VM_NAME}, template: ${VM_TEMPLATE}, FreeBSD version: ${FREEBSD_VERSION}"

# Create the VM
vm create -t ${VM_TEMPLATE} ${VM_NAME} || { echo "Failed to create VM"; exit 1; }
ssh-keygen -t ed25519 -f ${VM_DIR}/${VM_NAME}/id_ed25519 -N "" || { echo "Failed to generate SSH key"; exit 1; }
# Prepare zvol
zfs set volmode=geom ${STORAGE_POOL}/vm/${VM_NAME}/disk0 || { echo "Failed to set zvol mode"; exit 1; }

# Partition disk
gpart create -s gpt /dev/zvol/${STORAGE_POOL}/vm/${VM_NAME}/disk0 || { echo "Failed to create GPT partition table"; exit 1; }
gpart add -t efi -s 256M /dev/zvol/${STORAGE_POOL}/vm/${VM_NAME}/disk0 || { echo "Failed to add EFI partition"; exit 1; }
gpart add -t freebsd-ufs /dev/zvol/${STORAGE_POOL}/vm/${VM_NAME}/disk0 || { echo "Failed to add UFS partition"; exit 1; }

# Format partitions
newfs_msdos /dev/zvol/${STORAGE_POOL}/vm/${VM_NAME}/disk0p1 || { echo "Failed to format EFI partition"; exit 1; }
newfs /dev/zvol/${STORAGE_POOL}/vm/${VM_NAME}/disk0p2 || { echo "Failed to format UFS partition"; exit 1; }

# Create mount points and mount partitions
mkdir -p ${FREEBSD_INSTALL_DIR} || { echo "Failed to create mount point"; exit 1; }
mount /dev/zvol/${STORAGE_POOL}/vm/${VM_NAME}/disk0p2 ${FREEBSD_INSTALL_DIR} || { echo "Failed to mount root partition"; exit 1; }

# Check if FreeBSD base files exist in dist dir, if not download them
BASE_TXZFILE="base.txz"
KERNEL_TXZFILE="kernel.txz"
FREEBSD_MIRROR="https://download.freebsd.org/ftp/releases/amd64/${FREEBSD_VERSION}-RELEASE"

if [ ! -f "${DIST_DIR}/freebsd-${FREEBSD_VERSION}/base.txz" ] || [ ! -f "${DIST_DIR}/freebsd-${FREEBSD_VERSION}/kernel.txz" ]; then
    mkdir -p ${DIST_DIR}/freebsd-${FREEBSD_VERSION} || { echo "Failed to create ${DIST_DIR}/freebsd-${FREEBSD_VERSION} directory"; exit 1; }
    wget -O ${DIST_DIR}/freebsd-${FREEBSD_VERSION}/base.txz ${FREEBSD_MIRROR}/base.txz || { echo "Failed to download base.txz"; exit 1; }
    wget -O ${DIST_DIR}/freebsd-${FREEBSD_VERSION}/kernel.txz ${FREEBSD_MIRROR}/kernel.txz || { echo "Failed to download kernel.txz"; exit 1; }
fi

# Extract FreeBSD base system and kernel to root partition first
cd ${FREEBSD_INSTALL_DIR} || { echo "Failed to change to mount directory"; exit 1; }
echo "Extracting base system..."
tar -xpf ${DIST_DIR}/freebsd-${FREEBSD_VERSION}/base.txz --exclude="./boot/efi" -C ${FREEBSD_INSTALL_DIR} || { echo "Failed to extract base.txz"; exit 1; }
echo "Extracting kernel..."
tar -xpf ${DIST_DIR}/freebsd-${FREEBSD_VERSION}/kernel.txz -C ${FREEBSD_INSTALL_DIR} || { echo "Failed to extract kernel.txz"; exit 1; }

# Now create and mount EFI partition
mkdir -p ${FREEBSD_INSTALL_DIR}/boot/efi || { echo "Failed to create EFI mount point"; exit 1; }
mount -t msdosfs /dev/zvol/${STORAGE_POOL}/vm/${VM_NAME}/disk0p1 ${FREEBSD_INSTALL_DIR}/boot/efi || { echo "Failed to mount EFI partition"; exit 1; }

# Prepare chroot
mount -t devfs devfs ${FREEBSD_INSTALL_DIR}/dev || { echo "Failed to mount dev"; exit 1; }
cp /etc/resolv.conf ${FREEBSD_INSTALL_DIR}/etc/ || { echo "Failed to copy resolv.conf"; exit 1; }

# Create /etc/fstab for the VM
cat << EOF > ${FREEBSD_INSTALL_DIR}/etc/fstab || { echo "Failed to create fstab"; exit 1; }
# Device                Mountpoint      FStype  Options         Dump    Pass#
/dev/vtbd0p2            /               ufs     rw              1       1
/dev/vtbd0p1            /boot/efi       msdosfs rw              1       2
169.254.169.254:/usr/src /usr/src        nfs     rw,noauto       0       0
EOF

# Add SSH key to authorized_keys
mkdir -p ${FREEBSD_INSTALL_DIR}/root/.ssh
cat ${VM_DIR}/${VM_NAME}/id_ed25519.pub >> ${FREEBSD_INSTALL_DIR}/root/.ssh/authorized_keys
chmod 700 ${FREEBSD_INSTALL_DIR}/root/.ssh
chmod 600 ${FREEBSD_INSTALL_DIR}/root/.ssh/authorized_keys

# Create script to run inside chroot
cat << EOF > ${FREEBSD_INSTALL_DIR}/setup.sh || { echo "Failed to create setup script"; exit 1; }
#!/bin/sh
set -e

# VM template used for creation
VM_TEMPLATE="${VM_TEMPLATE}"
VM_NAME="${VM_NAME}"

# Print VM info
echo "Setting up VM '${VM_NAME}' created with template '${VM_TEMPLATE}'"

# Set hostname
echo hostname=\"${VM_NAME}\" > /etc/rc.conf

# Enable essential services
cat << 'RCCONF' >> /etc/rc.conf
# Configure network interface with autoipd instead of DHCP
ifconfig_vtnet0="up"
# Static dummy IPv6 config to ensure the interface stays up
ifconfig_vtnet0_ipv6="inet6 -ifdisabled"
# Enable needed services
sshd_enable="YES"
dumpdev="AUTO"
zfs_enable="YES"
ntpd_enable="YES"
dbus_enable="YES"
avahi_daemon_enable="YES"
avahi_dnsconfd_enable="YES"
lldpd_enable="YES"
# Set console to serial for VM
console="comconsole"
RCCONF

# Configure SSH server for key-based auth only
sed -i '' 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i '' 's/#PermitRootLogin no/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
sed -i '' 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config

# Create admin user with wheel group
pw useradd -n admin -m -G wheel -s /bin/sh
mkdir -p /home/admin/.ssh
cp /root/.ssh/authorized_keys /home/admin/.ssh/
chown -R admin:admin /home/admin/.ssh
chmod 700 /home/admin/.ssh
chmod 600 /home/admin/.ssh/authorized_keys

# Configure sudoers directory if it doesn't exist
mkdir -p /usr/local/etc/sudoers.d
echo '%wheel ALL=(ALL) ALL' > /usr/local/etc/sudoers.d/wheel
chmod 440 /usr/local/etc/sudoers.d/wheel

# Configure bootloader for serial console
cat << 'BOOTCONF' > /boot/loader.conf
boot_multicons="YES"
boot_serial="YES"
comconsole_speed="115200"
console="comconsole,vidconsole"
autoboot_delay="5"
BOOTCONF

# Create rc.local for avahi-autoipd setup
cat << 'RCLOCALEOF' > /etc/rc.local
#!/bin/sh
# Configure avahi-autoipd on boot
/usr/local/sbin/avahi-autoipd -D --no-chroot --force-bind vtnet0
echo "nameserver 127.0.0.1" > /etc/resolv.conf

# Create /usr/src if it doesn't exist
mkdir -p /usr/src

RCLOCALEOF
chmod +x /etc/rc.local

# Install some base packages
env ASSUME_ALWAYS_YES=yes pkg bootstrap
pkg install -y sudo vim-tiny bash curl ca_root_nss avahi-autoipd lldpd

# Set bash as admin's shell
chsh -s /usr/local/bin/bash admin

# Add EFI boot entries
mkdir -p /boot/efi/efi/boot
cp /boot/loader.efi /boot/efi/efi/boot/bootx64.efi

echo "FreeBSD installation completed successfully!"
EOF

# Make the script executable
chmod +x ${FREEBSD_INSTALL_DIR}/setup.sh || { echo "Failed to make setup script executable"; exit 1; }

# Run the script inside chroot
chroot ${FREEBSD_INSTALL_DIR} /setup.sh || { echo "Failed to run setup script in chroot"; exit 1; }

# Configure tap interface if specified
if [ -n "$TAP_INTERFACE" ]; then
    echo "Configuring VM to use network interface: ${TAP_INTERFACE}"
    echo "network0_device=\"${TAP_INTERFACE}\"" >> ${VM_DIR}/${VM_NAME}/${VM_NAME}.conf || { echo "Failed to update VM network configuration"; exit 1; }
fi

echo "Installation complete for VM '${VM_NAME}' with template '${VM_TEMPLATE}'."
echo "Start the VM with: vm start -f ${VM_NAME}"
