#!/usr/bin/env bash
# ================================================================
# MÓDULO 1: Migración estricta de systemd-boot → UKI
# Uso: ./migrate-uki.sh [nombre-del-kernel]
#   Sin argumento: autodetecta el kernel CachyOS instalado (no-LTS).
#   Con argumento: fuerza ese kernel, p.ej. "linux-cachyos-rc"
# ================================================================
set -euo pipefail

# Helpers de formato
OK()  { echo -e "\033[0;32m  ✔  \033[0m$*"; }
DIE() { echo -e "\033[0;31m  ✘  \033[0m$*"; exit 1; }
HDR() { echo -e "\n\033[1;36m══════  $* ══════\033[0m"; }

HDR "Comprobaciones previas"
[[ $EUID -eq 0 ]] || DIE "Ejecuta como root"

for cmd in mkinitcpio efibootmgr pacman bootctl findmnt file; do
    if command -v "$cmd" &>/dev/null; then
        OK "$cmd"
    else
        DIE "Herramienta faltante: $cmd"
    fi
done

bootctl is-installed &>/dev/null || DIE "systemd-boot no está instalado"
command -v ukify &>/dev/null || pacman -S --noconfirm systemd-ukify

HDR "Detectando kernel CachyOS instalado"
if [[ $# -ge 1 ]]; then
    kernel_name="$1"
    [[ -f "/boot/vmlinuz-${kernel_name}" ]] || DIE "No existe /boot/vmlinuz-${kernel_name}"
    OK "Kernel forzado por argumento: $kernel_name"
else
    # Busca vmlinuz-linux-cachyos* (rc, deckified, etc.), excluyendo LTS
    mapfile -t kernel_candidates < <(
        find /boot -maxdepth 1 -name 'vmlinuz-linux-cachyos*' -printf '%f\n' 2>/dev/null \
            | grep -iv 'lts' \
            | sed 's/^vmlinuz-//' \
            | sort
    )

    if [[ ${#kernel_candidates[@]} -eq 0 ]]; then
        DIE "No se encontró ningún kernel linux-cachyos* en /boot (excluyendo LTS)"
    elif [[ ${#kernel_candidates[@]} -gt 1 ]]; then
        DIE "Se detectaron varios kernels CachyOS: ${kernel_candidates[*]} — vuelve a ejecutar pasando cuál usar, p.ej.: $0 ${kernel_candidates[0]}"
    fi

    kernel_name="${kernel_candidates[0]}"
    OK "Kernel detectado: $kernel_name"
fi

HDR "Detectando hardware y configuración de arranque"
if findmnt /boot &>/dev/null && [[ -d /boot/EFI ]]; then
    ESP="/boot"
elif findmnt /efi &>/dev/null && [[ -d /efi/EFI ]]; then
    ESP="/efi"
else
    DIE "No se encontró el ESP montado"
fi

esp_dev=$(findmnt -n -o SOURCE "$ESP")
if [[ "$esp_dev" =~ ^/dev/(mmcblk[0-9]+|nvme[0-9]+n[0-9]+)p([0-9]+)$ ]]; then
    esp_disk="/dev/${BASH_REMATCH[1]}"
    esp_part="${BASH_REMATCH[2]}"
elif [[ "$esp_dev" =~ ^/dev/([a-z]+[a-z])([0-9]+)$ ]]; then
    esp_disk="/dev/${BASH_REMATCH[1]}"
    esp_part="${BASH_REMATCH[2]}"
else
    DIE "No se pudo determinar disco/partición (ESP en: $esp_dev)"
fi

# Localiza la entrada de loader/entries que apunta exactamente a este kernel,
# no por coincidencia de substring "cachyos" (que confundiría linux-cachyos
# con linux-cachyos-rc si ambos existieran como entradas).
entry_dir="$ESP/loader/entries"
[[ -d "$entry_dir" ]] || DIE "No existe $entry_dir"

entry_file=""
while IFS= read -r -d '' f; do
    if grep -qE "^linux[[:space:]]+.*vmlinuz-${kernel_name}\$" "$f"; then
        if [[ -n "$entry_file" ]]; then
            DIE "Varias entradas en $entry_dir referencian vmlinuz-${kernel_name}: $(basename "$entry_file") y $(basename "$f")"
        fi
        entry_file="$f"
    fi
done < <(find "$entry_dir" -maxdepth 1 -name "*.conf" -print0 2>/dev/null)

[[ -n "$entry_file" ]] || DIE "No se encontró la entrada de arranque para vmlinuz-${kernel_name}"
OK "Entrada de arranque: $(basename "$entry_file")"

# Extraer la cmdline original intacta
cmdline=$(grep -m1 '^options' "$entry_file" | sed 's/^options[[:space:]]*//')
[[ -n "$cmdline" ]] || DIE "No se pudo extraer 'options' de $entry_file"

HDR "Configurando entorno de Kernel y Generando UKI"
mkdir -p /etc/kernel/cmdline.d
cmdline_file="/etc/kernel/cmdline.d/root.conf"
echo "$cmdline" > "$cmdline_file"

preset_file="/etc/mkinitcpio.d/${kernel_name}.preset"
[[ -f "$preset_file" ]] || DIE "No existe $preset_file"
cp "$preset_file" "${preset_file}.bak"

uki_path="$ESP/EFI/Linux/${kernel_name}.efi"
cat > "$preset_file" << PRESET
# Modo UKI estricto (Corregido para CachyOS)
ALL_kver="/boot/vmlinuz-${kernel_name}"
PRESETS=('default')
default_uki="${uki_path}"
default_options="--splash /usr/share/systemd/bootctl/splash-arch.bmp --cmdline ${cmdline_file}"
PRESET

mkdir -p "$ESP/EFI/Linux"
mkinitcpio -p "$kernel_name"
[[ -f "$uki_path" ]] || DIE "Fallo al generar el UKI"
OK "UKI generado en $uki_path"

HDR "Configurando Entradas UEFI (NVRAM)"
bootx64="$ESP/EFI/BOOT/BOOTX64.EFI"
if [[ -f "$bootx64" ]]; then
    cp "$bootx64" "${bootx64}.bak"
    OK "Backup de BOOTX64.EFI creado"
fi

while read -r bootnum; do
    efibootmgr --delete-bootnum --bootnum "$bootnum" &>/dev/null || true
done < <(efibootmgr | grep -i "CachyOS" | grep -oP 'Boot\K[0-9A-Fa-f]+' || true)

efibootmgr --create --disk "$esp_disk" --part "$esp_part" --label "CachyOS" --loader "\\EFI\\Linux\\${kernel_name}.efi" --unicode &>/dev/null
OK "Entrada UEFI creada con éxito"

HDR "Removiendo subestructura de systemd-boot"
bootctl remove 2>/dev/null || true

mkdir -p "$ESP/EFI/BOOT"
cp "$uki_path" "$bootx64"  # Duplicado por seguridad en la ruta por defecto

if [[ -d "$ESP/loader" ]]; then
    rm -rf "$ESP/loader"
fi

# Limpieza de imágenes clásicas obsoletas
rm -f "/boot/initramfs-${kernel_name}.img" "/boot/initramfs-${kernel_name}-fallback.img"

OK "Migración a UKI limpia e independiente completada (kernel: ${kernel_name})."
