#!/usr/bin/env bash
# ================================================================
# MÓDULO 1: Migración estricta de systemd-boot → UKI
# ================================================================

set -euo pipefail

# Helpers de formato
OK()  { echo -e "\033[0;32m  ✔  \033[0m$*"; }
DIE() { echo -e "\033[0;31m  ✘  \033[0m$*"; exit 1; }
HDR() { echo -e "\n\033[1;033[0;36m══════  $* ══════\033[0m"; }

HDR "Comprobaciones previas"
[[ $EUID -eq 0 ]] || DIE "Ejecuta como root"

for cmd in mkinitcpio efibootmgr pacman bootctl findmnt file; do
    command -v "$cmd" &>/dev/null && OK "$cmd" || DIE "Herramienta faltante: $cmd"
done

bootctl is-installed &>/dev/null || DIE "systemd-boot no está instalado"
command -v ukify &>/dev/null || pacman -S --noconfirm systemd-ukify

HDR "Detectando hardware y configuración de arranque"
if findmnt /boot &>/dev/null && [[ -d /boot/EFI ]]; then ESP="/boot"
elif findmnt /efi &>/dev/null && [[ -d /efi/EFI ]]; then ESP="/efi"
else DIE "No se encontró el ESP montado"; fi

esp_dev=$(findmnt -n -o SOURCE "$ESP")

if [[ "$esp_dev" =~ ^/dev/(mmcblk[0-9]+|nvme[0-9]+n[0-9]+)p([0-9]+)$ ]]; then
    esp_disk="/dev/${BASH_REMATCH[1]}"
    esp_part="${BASH_REMATCH[2]}"
elif [[ "$esp_dev" =~ ^/dev/([a-z]+[a-z])([0-9]+)$ ]]; then
    esp_disk="/dev/${BASH_REMATCH[1]}"
    esp_part="${BASH_REMATCH[2]}"
else
    DIE "No se pudo determinar disco/partición"
fi

entry_dir="$ESP/loader/entries"
entry_file=$(find "$entry_dir" -maxdepth 1 -name "*.conf" | grep -i "cachyos" | grep -iv "lts" | head -1 || true)
[[ -n "$entry_file" ]] || DIE "No se encontró la configuración de linux-cachyos"

# Extraer la cmdline original intacta
cmdline=$(grep -m1 '^options' "$entry_file" | sed 's/^options[[:space:]]*//')

HDR "Configurando entorno de Kernel y Generando UKI"
mkdir -p /etc/kernel/cmdline.d
cmdline_file="/etc/kernel/cmdline.d/root.conf"
echo "$cmdline" > "$cmdline_file"

preset_file="/etc/mkinitcpio.d/linux-cachyos.preset"
cp "$preset_file" "${preset_file}.bak" 2>/dev/null || true
uki_path="$ESP/EFI/Linux/linux-cachyos.efi"

cat > "$preset_file" << PRESET
# Modo UKI estricto (Corregido para CachyOS)
ALL_kver="/boot/vmlinuz-linux-cachyos"
PRESETS=('default')
default_uki="${uki_path}"
default_options="--splash /usr/share/systemd/bootctl/splash-arch.bmp --cmdline ${cmdline_file}"
PRESET

mkdir -p "$ESP/EFI/Linux"
mkinitcpio -p linux-cachyos

[[ -f "$uki_path" ]] || DIE "Fallo al generar el UKI"

HDR "Configurando Entradas UEFI (NVRAM)"
bootx64="$ESP/EFI/BOOT/BOOTX64.EFI"
[[ -f "$bootx64" ]] && cp "$bootx64" "${bootx64}.bak"

while read -r bootnum; do
    efibootmgr --delete-bootnum --bootnum "$bootnum" &>/dev/null || true
done < <(efibootmgr | grep -i "CachyOS" | grep -oP 'Boot\K[0-9A-Fa-f]+' || true)

efibootmgr --create --disk "$esp_disk" --part "$esp_part" --label "CachyOS" --loader "\\EFI\\Linux\\linux-cachyos.efi" --unicode &>/dev/null
OK "Entrada UEFI creada con éxito"

HDR "Removiendo subestructura de systemd-boot"
bootctl remove 2>/dev/null || true
mkdir -p "$ESP/EFI/BOOT"
cp "$uki_path" "$bootx64" # Duplicado por seguridad en la ruta por defecto
[[ -d "$ESP/loader" ]] && rm -rf "$ESP/loader"

# Limpieza de imágenes clásicas obsoletas
rm -f /boot/initramfs-linux-cachyos.img /boot/initramfs-linux-cachyos-fallback.img
OK "Migración a UKI limpia e independiente completada."
