#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Configuration
HOSTNAME="rnoba"
TIMEZONE="America/Sao_Paulo"
LOCALE="en_US.UTF-8"
KEYMAP="us"
TARGET_DISK="/dev/nvme0n1"
EFI_SIZE="500MiB"
VOID_REPO="https://repo-default.voidlinux.org/current"
ARCH="x86_64"

# User configuration
USER_NAME="$HOSTNAME"
USER_PASSWORD="123"

# UUIDs will be set after formatting
EFI_UUID=""
ROOT_UUID=""

# Package list
PACKAGES=(
    grub grub-x86_64-efi efibootmgr dosfstools
    NetworkManager network-manager-applet dhcpcd
    dbus elogind nftables
    pipewire pulseaudio
    p7zip unzip
    alacritty zsh tmux i3 dmenu firefox mpv neovim flameshot
    base-devel gcc clang git curl direnv
    noto-fonts-ttf noto-fonts-cjk noto-fonts-emoji nerd-fonts
    vulkan-loader ripgrep xclip
    xorg xorg-server
    xtools sudo
)

# Logging functions
log_info()  { printf "%b[INFO]%b %s\n"  "$GREEN" "$NC" "$1"; }
log_warn()  { printf "%b[WARN]%b %s\n"  "$YELLOW" "$NC" "$1"; }
log_error() { printf "%b[ERROR]%b %s\n" "$RED"   "$NC" "$1" >&2; exit 1; }

# Pre-flight checks
check_root() { 
    [[ $EUID -eq 0 ]] || log_error "This script must be run as root"
}

check_uefi() { 
    [[ -d /sys/firmware/efi ]] || log_error "UEFI mode required. Please boot in UEFI mode."
}

check_network() {
    log_info "Checking network connectivity..."
    if ! ping -c 1 -W 2 voidlinux.org &>/dev/null; then
        log_warn "Network connectivity check failed. Installation may fail."
        read -p "Continue anyway? (y/N): " ans
        [[ "$ans" =~ ^[Yy]$ ]] || log_error "Installation cancelled"
    fi
}

# Get partition path helper
get_part() {
    local disk="$1" num="$2"
    if [[ $disk =~ nvme || $disk =~ mmcblk ]]; then 
        echo "${disk}p${num}"
    else 
        echo "${disk}${num}"
    fi
}

# Confirm disk wipe
confirm_disk() {
    log_warn "╔════════════════════════════════════════════════════════════╗"
    log_warn "║  WARNING: This will DESTROY ALL DATA on $TARGET_DISK       "
    log_warn "╚════════════════════════════════════════════════════════════╝"
    echo
    lsblk -f "$TARGET_DISK" 2>/dev/null || log_error "Disk $TARGET_DISK not found"
    echo
    read -p "Type 'YES' in capital letters to continue: " confirm
    [[ "$confirm" == "YES" ]] || log_error "Installation cancelled by user"
}

# Partition the disk
partition_disk() {
    log_info "Partitioning $TARGET_DISK..."
    
    # Wipe existing partition table
    wipefs -af "$TARGET_DISK" || log_error "Failed to wipe partition table"
    
    # Create GPT partition table
    parted -s "$TARGET_DISK" mklabel gpt || log_error "Failed to create GPT label"
    
    # Create EFI partition (500MB)
    parted -s "$TARGET_DISK" mkpart primary fat32 1MiB "$EFI_SIZE" || log_error "Failed to create EFI partition"
    parted -s "$TARGET_DISK" set 1 esp on || log_error "Failed to set ESP flag"
    
    # Create root partition (remaining space)
    parted -s "$TARGET_DISK" mkpart primary ext4 "$EFI_SIZE" 100% || log_error "Failed to create root partition"
    
    # Ensure kernel sees the changes
    sleep 2
    partprobe "$TARGET_DISK" 2>/dev/null || true
    sleep 2
    
    log_info "Partitioning completed successfully"
}

# Format partitions
format_partitions() {
    local efi_part=$(get_part "$TARGET_DISK" 1)
    local root_part=$(get_part "$TARGET_DISK" 2)

    log_info "Formatting partitions..."
    
    # Format EFI partition as FAT32
    mkfs.vfat -F32 "$efi_part" || log_error "Failed to format EFI partition"
    
    # Format root partition as ext4
    mkfs.ext4 -F "$root_part" || log_error "Failed to format root partition"

    # Get UUIDs
    EFI_UUID=$(blkid -s UUID -o value "$efi_part")
    ROOT_UUID=$(blkid -s UUID -o value "$root_part")

    [[ -n "$EFI_UUID" ]] || log_error "Failed to get EFI UUID"
    [[ -n "$ROOT_UUID" ]] || log_error "Failed to get ROOT UUID"

    log_info "Formatting completed (EFI: $EFI_UUID | Root: $ROOT_UUID)"
}

# Mount partitions
mount_partitions() {
    local efi_part=$(get_part "$TARGET_DISK" 1)
    local root_part=$(get_part "$TARGET_DISK" 2)

    log_info "Mounting partitions..."
    
    # Mount root
    mount "$root_part" /mnt || log_error "Failed to mount root partition"
    
    # Create and mount EFI at /boot (not /boot/efi)
    mkdir -p /mnt/boot || log_error "Failed to create /boot directory"
    mount "$efi_part" /mnt/boot || log_error "Failed to mount EFI partition"
    
    log_info "Partitions mounted successfully"
}

# Generate fstab using xgenfstab (proper method)
generate_fstab() {
    log_info "Generating /etc/fstab using xgenfstab..."
    
    # Install xtools if not present
    if ! command -v xgenfstab &>/dev/null; then
        log_info "Installing xtools for xgenfstab..."
        xbps-install -Sy xtools || log_error "Failed to install xtools"
    fi
    
    # Generate fstab with UUIDs
    xgenfstab -U /mnt > /mnt/etc/fstab || log_error "Failed to generate fstab"
    
    log_info "fstab generated successfully"
    cat /mnt/etc/fstab
}

# Install base system
install_base_system() {
    log_info "Bootstrapping base-system..."
    export XBPS_ARCH="$ARCH"

    # Copy RSA keys
    mkdir -p /mnt/var/db/xbps/keys
    cp /var/db/xbps/keys/* /mnt/var/db/xbps/keys/ 2>/dev/null || true

    # Install base-system
    XBPS_ARCH="$ARCH" xbps-install -Sy -r /mnt -R "$VOID_REPO" base-system || \
        log_error "Failed to install base-system"
    
    log_info "base-system installed successfully"
}

# Update XBPS and system
update_xbps_and_system() {
    log_info "Updating xbps and system packages..."
    
    xbps-install -r /mnt -Su xbps || log_error "Failed to update xbps"
    xbps-install -r /mnt -Su || log_error "Failed to update system"
    
    log_info "System updated successfully"
}

# Install additional packages
install_additional_packages() {
    log_info "Installing additional packages..."
    
    xbps-install -Sy -r /mnt -R "$VOID_REPO" "${PACKAGES[@]}" || \
        log_error "Failed to install additional packages"
    
    log_info "Additional packages installed successfully"
}

# Configure system basics
configure_system() {
    log_info "Configuring system..."

    # Hostname
    echo "$HOSTNAME" > /mnt/etc/hostname

    # Hosts file
    cat > /mnt/etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOF

    # Locale
    echo "$LOCALE UTF-8" > /mnt/etc/default/libc-locales
    echo "LANG=$LOCALE" > /mnt/etc/locale.conf

    # Timezone
    ln -sf "/usr/share/zoneinfo/$TIMEZONE" /mnt/etc/localtime

    # Keymap
    echo "KEYMAP=$KEYMAP" > /mnt/etc/rc.conf

    log_info "System configuration completed"
}

# Configure dracut for hostonly initramfs
configure_dracut() {
    log_info "Configuring dracut..."
    
    mkdir -p /mnt/etc/dracut.conf.d
    cat > /mnt/etc/dracut.conf.d/10-hostonly.conf <<EOF
hostonly=yes
hostonly_cmdline=yes
EOF
    
    log_info "Dracut configured"
}

# No need for manual chroot setup - xchroot handles this
# xchroot will automatically set up proc, sys, dev, and resolv.conf

# Configure locales and reconfigure packages
chroot_reconfigure() {
    log_info "Reconfiguring packages using xchroot..."
    
    xchroot /mnt /bin/bash <<'CHROOT_END'
set -e

# Generate locales
echo "Generating locales..."
xbps-reconfigure -f glibc-locales

# Reconfigure all packages
echo "Reconfiguring all packages..."
xbps-reconfigure -fa
CHROOT_END
    
    [[ $? -eq 0 ]] || log_error "Chroot reconfiguration failed"
    log_info "Package reconfiguration completed"
}

# Install GRUB bootloader
install_bootloader() {
    log_info "Installing GRUB bootloader..."
    
    xchroot /mnt /bin/bash <<'CHROOT_END'
set -e

# Install GRUB to EFI
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=void --recheck

# Generate GRUB config
grub-mkconfig -o /boot/grub/grub.cfg
CHROOT_END
    
    [[ $? -eq 0 ]] || log_error "GRUB installation failed"
    log_info "GRUB installed successfully"
}

# Enable essential services
enable_services() {
    log_info "Enabling essential services..."
    
    for svc in NetworkManager dbus elogind; do
        if [[ -d /mnt/etc/sv/"$svc" ]]; then
            ln -sf /etc/sv/"$svc" /mnt/etc/runit/runsvdir/default/ || \
                log_warn "Failed to enable service: $svc"
        else
            log_warn "Service directory not found: $svc"
        fi
    done
    
    log_info "Services enabled"
}

# Configure zram for swap
configure_zram() {
    log_info "Setting up zram (50% of RAM)..."
    
    cat > /mnt/etc/rc.local <<'EOF'
#!/bin/sh
# Load zram module
modprobe zram

# Configure zram0
echo zstd > /sys/block/zram0/comp_algorithm
echo $(awk '/MemTotal/ {printf "%.0f", $2 * 0.5 * 1024}' /proc/meminfo) > /sys/block/zram0/disksize

# Enable as swap
mkswap /dev/zram0
swapon /dev/zram0 -p 100
EOF
    
    chmod +x /mnt/etc/rc.local
    log_info "zram configured"
}

# Set root password
set_root_password() {
    log_info "Setting root password..."
    
    xchroot /mnt /bin/bash <<CHROOT_END
set -e
echo "root:root" | chpasswd
CHROOT_END
    
    [[ $? -eq 0 ]] || log_error "Failed to set root password"
    log_info "Root password set to: root"
}

# Create user with hostname as username
create_user() {
    log_info "Creating user '$USER_NAME'..."
    
    xchroot /mnt /bin/bash <<CHROOT_END
set -e

# Create user
useradd -m -G wheel,audio,video,input,storage,optical -s /bin/bash "$USER_NAME"

# Set password
echo "$USER_NAME:$USER_PASSWORD" | chpasswd

# Configure sudo for wheel group
if ! grep -q "^%wheel ALL=(ALL:ALL) ALL" /etc/sudoers; then
    echo "%wheel ALL=(ALL:ALL) ALL" >> /etc/sudoers
fi
CHROOT_END
    
    [[ $? -eq 0 ]] || log_error "Failed to create user"
    log_info "User '$USER_NAME' created with password: $USER_PASSWORD"
}

# Cleanup mounts
cleanup() {
    log_info "Cleaning up mounts..."
    
    # Only unmount our actual filesystems
    # xchroot handles cleanup of proc, sys, dev automatically
    umount -R /mnt/boot 2>/dev/null || true
    umount -R /mnt 2>/dev/null || true
    
    log_info "Cleanup completed"
}

# Display installation summary
show_summary() {
    echo
    echo "════════════════════════════════════════════════════════════════"
    log_info "Installation Summary"
    echo "════════════════════════════════════════════════════════════════"
    echo "Disk:          $TARGET_DISK"
    echo "EFI partition: $(get_part "$TARGET_DISK" 1) (UUID: $EFI_UUID)"
    echo "Root partition: $(get_part "$TARGET_DISK" 2) (UUID: $ROOT_UUID)"
    echo "Hostname:      $HOSTNAME"
    echo "Timezone:      $TIMEZONE"
    echo "Locale:        $LOCALE"
    echo "Keymap:        $KEYMAP"
    echo
    echo "Credentials:"
    echo "  Root password:     root"
    echo "  User:              $USER_NAME"
    echo "  User password:     $USER_PASSWORD"
    echo "════════════════════════════════════════════════════════════════"
    echo
}

# Main installation workflow
main() {
    log_info "Void Linux Production Installer Starting..."
    echo

    # Pre-flight checks
    check_root
    check_uefi
    check_network
    
    # Disk operations
    confirm_disk
    partition_disk
    format_partitions
    mount_partitions
    
    # Install system
    install_base_system
    update_xbps_and_system
    install_additional_packages
    
    # Configure system
    configure_system
    generate_fstab
    configure_dracut
    enable_services
    configure_zram
    
    # Chroot operations (xchroot handles all mount setup automatically)
    chroot_reconfigure
    set_root_password
    create_user
    install_bootloader
    
    # Finalize
    cleanup
    show_summary

    log_info "Installation completed successfully!"
    echo
    echo "You can now reboot into your new Void Linux system."
    echo
    read -p "Reboot now? (y/N): " ans
    [[ "$ans" =~ ^[Yy]$ ]] && reboot || log_info "Remember to reboot before using the system!"
}

# Trap errors
trap 'log_error "Installation failed at line $LINENO"' ERR

# Run main
main "$@"
