#!/usr/bin/env bash
# ================================================================
# MÓDULO 2: Optimizaciones críticas de arranque y depuración
# Uso: ./boot-optimizations.sh [nombre-del-kernel]
#   Sin argumento: autodetecta el kernel CachyOS instalado (no-LTS).
#   Con argumento: fuerza ese kernel, p.ej. "linux-cachyos-rc"
# ================================================================

set -euo pipefail

OK()  { echo -e "\033[0;32m  ✔  \033[0m$*"; }
WRN() { echo -e "\033[1;33m  ⚠  \033[0m$*"; }
DIE() { echo -e "\033[0;31m  ✘  \033[0m$*"; exit 1; }
HDR() { echo -e "\n\033[1;36m══════  $* ══════\033[0m"; }

[[ $EUID -eq 0 ]] || DIE "Ejecuta como root"

needs_rebuild=0

HDR "Detectando kernel CachyOS instalado"
if [[ $# -ge 1 ]]; then
    kernel_name="$1"
    [[ -f "/boot/vmlinuz-${kernel_name}" ]] || DIE "No existe /boot/vmlinuz-${kernel_name}"
    OK "Kernel forzado por argumento: $kernel_name"
else
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

# 1. PURGA DE KERNELS INNECESARIOS (Aceleración de compilaciones futuras)
HDR "Evaluando Kernel LTS"
lts_pkgs=()
for pkg in linux-cachyos-lts linux-cachyos-lts-headers; do
    pacman -Qi "$pkg" &>/dev/null && lts_pkgs+=("$pkg")
done

if [ ${#lts_pkgs[@]} -gt 0 ]; then
    if pacman -Rs --noconfirm "${lts_pkgs[@]}"; then
        OK "Kernel LTS removido"
        rm -f /boot/initramfs-linux-cachyos-lts.img /boot/initramfs-linux-cachyos-lts-fallback.img
    else
        DIE "No se pudo desinstalar el kernel LTS; no se tocan sus initramfs"
    fi
else
    OK "No se detectó kernel LTS secundario"
fi

# 2. OPTIMIZACIÓN DE PARAMETROS DE KERNEL (CMDLINE)
HDR "Ajustando argumentos de inicialización del Kernel"
cmdline_file="/etc/kernel/cmdline.d/root.conf"

if [[ -f "$cmdline_file" ]]; then
    cmdline=$(cat "$cmdline_file")

    # Quitar 'splash' como token completo (respetando límites de palabra)
    read -ra tokens <<< "$cmdline"
    filtered=()
    for tok in "${tokens[@]}"; do
        [[ "$tok" == "splash" ]] || filtered+=("$tok")
    done

    # - rootflags=noatime: Apaga la actualización de metadatos de acceso en discos duros/SSDs
    # - 8250.nr_uarts=0: No pierde ciclos de reloj buscando puertos serie (antiguos) inexistentes
    # - udev.log_level=3: Evita que el buffer de logs de udev colapse el inicio temprano con advertencias no críticas
    declare -A opts=(
        ["rootflags"]="rootflags=noatime"
        ["8250.nr_uarts"]="8250.nr_uarts=0"
        ["udev.log_level"]="udev.log_level=3"
    )
    for key in "${!opts[@]}"; do
        already_present=0
        for tok in "${filtered[@]}"; do
            [[ "$tok" == "$key"* ]] && already_present=1 && break
        done
        [[ $already_present -eq 0 ]] && filtered+=("${opts[$key]}")
    done

    new_cmdline="${filtered[*]}"
    if [[ "$new_cmdline" != "$cmdline" ]]; then
        echo "$new_cmdline" > "$cmdline_file"
        needs_rebuild=1
        OK "Parámetros aplicados en cmdline: $new_cmdline"
    else
        OK "cmdline ya estaba optimizada, sin cambios"
    fi
else
    WRN "No se encontró un archivo de cmdline centralizado para optimizar."
fi

# 3. ALIGERAR INITRAMFS (Eliminación de Hooks pesados)
HDR "Modificando estructura de mkinitcpio"
mkinitcpio_conf="/etc/mkinitcpio.conf"

if [[ -f "$mkinitcpio_conf" ]]; then
    cp "$mkinitcpio_conf" "${mkinitcpio_conf}.bak"
    hooks_removed=0
    for hook in plymouth kms; do
        if grep -qP "^HOOKS=.*\b${hook}\b" "$mkinitcpio_conf"; then
            sed -i -E "/^HOOKS=/s/([([:space:]])${hook}([[:space:]])/\1\2/g; /^HOOKS=/s/([([:space:]])${hook}\)/\1)/g" "$mkinitcpio_conf"
            if grep -qP "^HOOKS=.*\b${hook}\b" "$mkinitcpio_conf"; then
                WRN "No se pudo eliminar el hook '${hook}' automáticamente, revísalo a mano"
            else
                OK "Hook '${hook}' eliminado para aligerar la carga en memoria inicial"
                needs_rebuild=1
                hooks_removed=1
            fi
        fi
    done
    [[ $hooks_removed -eq 0 ]] && OK "HOOKS ya estaba optimizado, sin plymouth/kms que eliminar"
else
    WRN "No se encontró $mkinitcpio_conf, no se tocan los HOOKS"
fi

# 3b. REGENERAR INITRAMFS/UKI SI HUBO CAMBIOS
if [[ $needs_rebuild -eq 1 ]]; then
    HDR "Regenerando initramfs/UKI con los cambios aplicados"
    if command -v mkinitcpio &>/dev/null && [[ -f "/etc/mkinitcpio.d/${kernel_name}.preset" ]]; then
        mkinitcpio -p "$kernel_name"
        OK "initramfs/UKI regenerado para $kernel_name"
    else
        WRN "No se encontró el preset de ${kernel_name}; regenera el initramfs manualmente"
    fi
else
    HDR "Sin cambios de cmdline/HOOKS"
    OK "No hace falta regenerar el initramfs/UKI"
fi

# 4. ENMASCARADO DE SERVICIOS CRÍTICOS DE SYSTEMD
HDR "Deshabilitando servicios paralelos innecesarios"

plymouth_svcs=(plymouth-start.service plymouth-quit.service plymouth-quit-wait.service plymouth-read-write.service)
for svc in "${plymouth_svcs[@]}"; do
    if systemctl list-unit-files "$svc" 2>/dev/null | grep -q "$svc"; then
        systemctl disable "$svc" &>/dev/null || true
        systemctl mask "$svc" &>/dev/null
        OK "Enmascarado profundo: $svc"
    fi
done

nm_wait="NetworkManager-wait-online.service"
if systemctl list-unit-files "$nm_wait" 2>/dev/null | grep -q "$nm_wait"; then
    systemctl disable "$nm_wait" &>/dev/null || true
    systemctl mask "$nm_wait" &>/dev/null
    OK "Enmascarado: $nm_wait (El login ya no esperará por internet)"
fi

HDR "Optimizaciones de rendimiento de software concluidas."
