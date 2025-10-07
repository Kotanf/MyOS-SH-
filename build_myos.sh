#!/usr/bin/env bash
# build_myos.sh
# Full automated build of MyOS Linux Distro
# Kernel 6.17.1 + GNOME 49 + WhiteSur + Wine/Proton/Bottles + Reset OS

set -e
set -o pipefail

LFS="${HOME}/MyOS"
KERNEL_URL="https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.17.1.tar.xz"
KERNEL_DIR="linux-6.17.1"
NUM_JOBS=$(nproc)
LOG="$LFS/build.log"
ERRLOG="$LFS/build_error.log"

mkdir -p "$LFS"
: > "$LOG"
: > "$ERRLOG"
cd "$LFS"

# Logging functions
log() { echo "[INFO] $*" | tee -a "$LOG"; }
err() { echo "[ERROR] $*" | tee -a "$LOG" "$ERRLOG" >&2; }

# Check sudo
if ! sudo -v >/dev/null 2>&1; then
    echo "Root privileges required!"
    exit 1
fi

log "=== MyOS Build Started ==="

# -----------------------
# 1) Install required packages
# -----------------------
log "Installing development tools and Fedora essentials..."
sudo dnf -y groupinstall "Development Tools"
sudo dnf -y install bison gawk m4 texinfo wget xorriso grub2-tools python3 git vim nano \
gnome-shell gnome-session gdm mutter nautilus gnome-control-center epel-release curl cabextract zenity

log "Installing Wine, Proton and Bottles..."
sudo dnf -y install wine wine-core wine-devel winetricks
sudo dnf -y copr enable proton/experimental
sudo dnf -y install protontricks bottles

# -----------------------
# 2) Download and build Linux Kernel
# -----------------------
if [ ! -f "${LFS}/linux-6.17.1.tar.xz" ]; then
    log "Downloading Linux Kernel 6.17.1..."
    wget -c "$KERNEL_URL"
fi
if [ ! -d "$KERNEL_DIR" ]; then
    tar -xf linux-6.17.1.tar.xz
fi

cd "$KERNEL_DIR"
log "Building Kernel..."
make defconfig
make -j"$NUM_JOBS"
sudo make modules_install INSTALL_MOD_PATH="$LFS"
sudo cp arch/x86/boot/bzImage "$LFS/boot/vmlinuz-6.17.1"

# -----------------------
# 3) Minimal RootFS
# -----------------------
cd "$LFS"
mkdir -pv {bin,sbin,boot,dev,etc,proc,sys,usr,var,home,tmp,lib}
chmod 1777 tmp

# BusyBox
BUSYBOX_VER="1.36.0"
if [ ! -f "busybox-$BUSYBOX_VER.tar.bz2" ]; then
    wget -c "https://busybox.net/downloads/busybox-$BUSYBOX_VER.tar.bz2"
fi
tar -xf "busybox-$BUSYBOX_VER.tar.bz2"
cd "busybox-$BUSYBOX_VER"
make defconfig
make -j"$NUM_JOBS"
make CONFIG_PREFIX="$LFS" install

# -----------------------
# 4) Init script
# -----------------------
cat > "$LFS/init" <<'EOF'
#!/bin/sh
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
echo
echo "Welcome to MyOS Linux"
exec /bin/sh
EOF
chmod +x "$LFS/init"

# -----------------------
# 5) Basic /etc and device nodes
# -----------------------
mkdir -p "$LFS/etc"
echo "my_os" > "$LFS/etc/hostname"
cat > "$LFS/etc/fstab" <<FSTAB
proc    /proc   proc    defaults    0   0
sysfs   /sys    sysfs   defaults    0   0
devtmpfs /dev   devtmpfs defaults    0   0
FSTAB

sudo mknod -m 666 "$LFS/dev/null" c 1 3
sudo mknod -m 666 "$LFS/dev/zero" c 1 5
sudo mknod -m 600 "$LFS/dev/console" c 5 1
sudo mknod -m 666 "$LFS/dev/tty" c 5 0

# -----------------------
# 6) GNOME 49 + WhiteSur theme
# -----------------------
log "Installing GNOME 49..."
sudo dnf -y copr enable gnome-49/gnome-49
sudo dnf -y install gnome-shell gdm nautilus mutter gnome-control-center gnome-session

log "Applying WhiteSur theme..."
cd "$LFS"
if [ ! -d "WhiteSur-gtk-theme" ]; then
    git clone https://github.com/vinceliuice/WhiteSur-gtk-theme.git
fi
cd WhiteSur-gtk-theme
./install.sh

# -----------------------
# 7) Wine/Proton/Bottles setup
# -----------------------
log "Configuring Wine/Proton/Bottles..."
mkdir -p "$LFS/home/user/.wine"
wineboot -i
bottles-cli create "DefaultBottle"

# -----------------------
# 8) Factory reset integration
# -----------------------
mkdir -p "$LFS/etc.factory"
cp -r "$LFS/etc" "$LFS/etc.factory"

cat > "$LFS/usr/local/bin/reset-to-factory.sh" <<'RESET'
#!/bin/bash
LOG="/var/log/reset_factory.log"
echo "$(date) - Reset started" >> "$LOG"

if [ "$EUID" -ne 0 ]; then
    zenity --error --text="Root privileges required!"
    exit 1
fi

zenity --question --title="Factory Reset" \
--text="All user data will be erased! Continue?" --ok-label="Yes" --cancel-label="No"

if [ $? -ne 0 ]; then exit 0; fi

PASSWORD=$(zenity --password --title="Confirm Admin Password")
echo "$PASSWORD" | sudo -S true || { zenity --error --text="Wrong password"; exit 1; }

rm -rf /home/*
cp -r /etc.factory/* /etc/
systemctl restart gdm

zenity --info --title="Reset Completed" --text="OS has been reset to factory settings. Reboot now."
echo "$(date) - Reset completed" >> "$LOG"
RESET
chmod +x "$LFS/usr/local/bin/reset-to-factory.sh"

cat > "$LFS/usr/share/applications/reset_factory.desktop" <<DESKTOP
[Desktop Entry]
Name=Factory Reset
Comment=Reset entire OS and user data
Exec=sudo /usr/local/bin/reset-to-factory.sh
Icon=system-software-update
Terminal=false
Type=Application
Categories=System;
DESKTOP

# -----------------------
# 9) Build Live ISO
# -----------------------
ISO_DIR="$LFS/iso"
mkdir -pv "$ISO_DIR/boot/grub"
cp "$LFS/boot/vmlinuz-6.17.1" "$ISO_DIR/boot/vmlinuz"
cp "$LFS/init" "$ISO_DIR/init"

cat > "$ISO_DIR/boot/grub/grub.cfg" <<GRUBCFG
set timeout=5
set default=0
menuentry "MyOS 6.17.1 (live)" {
    linux /boot/vmlinuz
    initrd /init
}
GRUBCFG

ISO_OUT="$HOME/MyOS_Live.iso"
log "Creating ISO..."
sudo grub-mkrescue -o "$ISO_OUT" "$ISO_DIR"

log "=== MyOS Build Completed ==="
log "ISO ready at: $ISO_OUT"
log "Test with: qemu-system-x86_64 -cdrom $ISO_OUT -m 2048 -boot d"