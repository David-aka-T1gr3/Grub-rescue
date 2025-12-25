#!/bin/bash
set -e

DRY_RUN=0
if [ "$1" = "--dry-run" ]; then
    DRY_RUN=1
    echo "MODO DRY-RUN ACTIVADO (no se harán cambios)"
fi

run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "[DRY-RUN] $*"
    else
        eval "$@"
    fi
}

echo "==============================================="
echo "   Reparación automática e interactiva de GRUB"
echo "==============================================="

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OFFLINE_DIR="$SCRIPT_DIR/grub-offline"

echo
echo "[*] Mostrando particiones disponibles:"
lsblk -f
echo

read -p "Ingresa la partición raíz Linux (ej: /dev/sda2): " PART_ROOT
read -p "Si usas UEFI, ingresa la partición EFI (ej: /dev/sda1). Si no, deja vacío: " PART_EFI
read -p "Si tienes /boot separado, ingresa la partición. Si no, déjalo vacío: " PART_BOOT

echo "[1/9] Montando partición raíz..."
run "mount $PART_ROOT /mnt"

if [ -n "$PART_BOOT" ]; then
    run "mount $PART_BOOT /mnt/boot"
fi

if [ -n "$PART_EFI" ]; then
    run "mkdir -p /mnt/boot/efi"
    run "mount $PART_EFI /mnt/boot/efi"
fi

echo "[4/9] Montando sistemas virtuales..."
run "mount --bind /dev /mnt/dev"
run "mount --bind /dev/pts /mnt/dev/pts"
run "mount --bind /proc /mnt/proc"
run "mount --bind /sys /mnt/sys"
run "mount --bind /run /mnt/run"
run "mount --bind $OFFLINE_DIR /mnt/grub-offline"

if [ "$DRY_RUN" -eq 1 ]; then
    echo "[DRY-RUN] Se entraría en chroot y se repararía GRUB"
else
chroot /mnt /bin/bash << 'EOF'
set -e

if ! command -v dpkg >/dev/null 2>&1; then
    echo "Sistema no Debian-based. Abortando."
    exit 1
fi

if [ -d /sys/firmware/efi ]; then
    MODE="UEFI"
else
    MODE="BIOS"
fi

if [ "$MODE" = "UEFI" ]; then
    PKG_MAIN="grub-efi-amd64"
else
    PKG_MAIN="grub-pc"
fi

if ! dpkg -s "$PKG_MAIN" >/dev/null 2>&1; then
    if ls /grub-offline/*.deb >/dev/null 2>&1; then
        dpkg -i /grub-offline/*.deb || true
        apt-get -f install -y || true
    else
        read -p "No hay paquetes offline. ¿Intentar Internet? (s/N): " RESP
        if [[ "$RESP" =~ ^[sS]$ ]]; then
            ping -c1 8.8.8.8 >/dev/null 2>&1 || exit 1
            apt update
            apt install -y "$PKG_MAIN"
        else
            exit 1
        fi
    fi
fi

if [ "$MODE" = "UEFI" ]; then
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
else
    read -p "Disco donde instalar GRUB (ej: /dev/sda): " DISK
    grub-install "$DISK"
fi

if command -v update-grub >/dev/null 2>&1; then
    update-grub
else
    grub-mkconfig -o /boot/grub/grub.cfg
fi
EOF
fi

echo "[9/9] Desmontando particiones..."
run "umount -R /mnt"

echo "Proceso finalizado."