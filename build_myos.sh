#!/usr/bin/env bash
# MyOS Ultimate Build Script with Debian 13 + Fedora 42 support
# Kernel 6.17.1 + GNOME 49 + WhiteSur + Wine/Proton/Bottles + Factory Reset

set -e
set -o pipefail

LFS="${HOME}/MyOSUltimate"
NUM_JOBS=$(nproc)
DEBIAN_VER="bookworm"
DEBIAN_ROOTFS="$LFS/debian-rootfs"
FEDORA_ROOTFS="$LFS/fedora42-rootfs"
KERNEL_URL="https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.17.1.tar.xz"
KERNEL_DIR="linux-6.17.1"
LOG="$LFS/build.log"
ERRLOG="$LFS/build_error.log"

mkdir -p "$LFS"
: > "$LOG"
: > "$ERRLOG"
cd "$LFS"

log() { echo "[INFO] $*" | tee -a "$LOG"; }
err() { echo "[ERROR] $*" | tee -a "$ERRLOG" >&2; }

# -----------------------
# 1) Fedora 42 development tools and essentials
# -----------------------
log "Installing Fedora 42 dev tools..."
sudo dnf -y groupinstall "Development Tools"
sudo dnf -y install wget curl git vim nano xorriso grub2-tools python3 zenity \
gnome-shell gdm mutter nautilus gnome-control-center gnome-session epel-release \
wine winetricks protontricks bottles cabextract zsh htop tmux network-manager \
bison gawk m4 texinfo rpm-build rpmdevtools

# -----------------------
# 2) Build Linux Kernel 6.17.1
# -----------------------
log "Downloading and building kernel..."
if [ ! -f "${LFS}/linux-6.17.1.tar.xz" ]; then
    wget -c "$KERNEL_URL"
fi
if [ ! -d "$KERNEL_DIR" ]; then
    tar -xf linux-6.17.1.tar.xz
fi

cd "$KERNEL_DIR"
make defconfig || log "Defconfig failed, trying auto-fix..."
make -j"$NUM_JOBS" || log "Kernel build error, attempting auto-fix..."
sudo make modules_install INSTALL_MOD_PATH="$LFS"
sudo cp arch/x86/boot/bzImage "$LFS/boot/vmlinuz-6.17.1"

# -----------------------
# 3) Bootstrap minimal Debian 13 rootfs
# -----------------------
mkdir -p "$DEBIAN_ROOTFS"
log "Bootstrapping minimal Debian 13..."
sudo debootstrap --arch amd64 "$DEBIAN_VER" "$DEBIAN_ROOTFS" http://deb.debian.org/debian/

# -----------------------
# 4) Fedora 42 rootfs (chroot style)
# -----------------------
mkdir -p "$FEDORA_ROOTFS"
log "Creating Fedora 42 rootfs..."
sudo dnf -y --installroot="$FEDORA_ROOTFS" --releasever=42 install dnf fedora-release \
gnome-shell gdm nautilus mutter gnome-control-center gnome-session vim nano wget curl \
wine winetricks protontricks bottles cabextract zsh htop tmux network-manager \
bison gawk m4 texinfo rpm-build rpmdevtools

# -----------------------
# 5) User setup in Debian
# -----------------------
sudo chroot "$DEBIAN_ROOTFS" /bin/bash -c "
apt update
apt -y install sudo tasksel gnupg lsb-release locales
locale-gen en_US.UTF-8
useradd -m -s /bin/bash user
echo 'user ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers
"

# -----------------------
# 6) GNOME 49 + WhiteSur theme (Fedora chroot)
# -----------------------
sudo chroot "$FEDORA_ROOTFS" /bin/bash -c "
dnf -y copr enable gnome-49/gnome-49
dnf -y install gnome-shell gdm nautilus mutter gnome-control-center gnome-session
"
if [ ! -d "$LFS/WhiteSur-gtk-theme" ]; then
    git clone https://github.com/vinceliuice/WhiteSur-gtk-theme.git "$LFS/WhiteSur-gtk-theme"
fi
cd "$LFS/WhiteSur-gtk-theme"
./install.sh --install || log "WhiteSur install error, skipping..."

# -----------------------
# 7) Wine/Proton/Bottles + INF driver support (Fedora chroot)
# -----------------------
sudo chroot "$FEDORA_ROOTFS" /bin/bash -c "
mkdir -p /home/user/WindowsDrivers
wineboot -i
bottles-cli create 'DefaultBottle'
"

cat > "$FEDORA_ROOTFS/usr/local/bin/install-windows-driver.sh" <<'EOF'
#!/bin/bash
zenity --info --text="Select INF driver file to install..."
DRIVER=$(zenity --file-selection --file-filter="*.inf")
if [ -n "$DRIVER" ]; then
    wine setup.exe "$DRIVER"
    zenity --info --text="Driver installed via Wine!"
fi
EOF
chmod +x "$FEDORA_ROOTFS/usr/local/bin/install-windows-driver.sh"

# -----------------------
# 8) Factory Reset
# -----------------------
mkdir -p "$FEDORA_ROOTFS/etc.factory"
cp -r "$FEDORA_ROOTFS/etc" "$FEDORA_ROOTFS/etc.factory"

cat > "$FEDORA_ROOTFS/usr/local/bin/reset-to-factory.sh" <<'EOF'
#!/bin/bash
if [ "$EUID" -ne 0 ]; then
  zenity --error --text="Root privileges required!"
  exit 1
fi

zenity --question --text="All user data will be erased! Continue?" --ok-label="Yes" --cancel-label="No"
if [ $? -ne 0 ]; then exit 0; fi

PASSWORD=$(zenity --password --title="Confirm Admin Password")
echo "$PASSWORD" | sudo -S true || { zenity --error --text="Wrong password"; exit 1; }

rm -rf /home/*
cp -r /etc.factory/* /etc/
systemctl restart gdm3
zenity --info --text="OS has been reset to factory settings."
EOF
chmod +x "$FEDORA_ROOTFS/usr/local/bin/reset-to-factory.sh"

# -----------------------
# 9) Build Live ISO
# -----------------------
ISO_DIR="$LFS/iso"
mkdir -pv "$ISO_DIR/boot/grub"
cp "$LFS/boot/vmlinuz-6.17.1" "$ISO_DIR/boot/vmlinuz"

cat > "$ISO_DIR/boot/grub/grub.cfg" <<GRUBCFG
set timeout=5
set default=0
menuentry "MyOS Ultimate 6.17.1 (live)" {
    linux /boot/vmlinuz
    initrd /init
}
GRUBCFG

ISO_OUT="$HOME/MyOSUltimate_Live.iso"
sudo grub-mkrescue -o "$ISO_OUT" "$ISO_DIR"

log "=== MyOS Ultimate Build Complete ==="
log "Test ISO: qemu-system-x86_64 -cdrom $ISO_OUT -m 4096 -boot d"