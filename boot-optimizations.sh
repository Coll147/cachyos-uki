#!/usr/bin/env bash
# ================================================================
# MÓDULO 2: Optimizaciones críticas de arranque y depuración
# ================================================================

set -euo pipefail

OK()  { echo -e "\033[0;32m  ✔  \033[0m$*"; }
WRN() { echo -e "\033[1;33m  ⚠  \033[0m$*"; }
DIE() { echo -e "\033[0;31m  ✘  \033[0m$*"; exit 1; }
HDR() { echo -e "\n\033[1;36m══════  $* ══════\033[0m"; }

[[ $EUID -eq 0 ]] || DIE "Ejecuta como root"

needs_rebuild=0

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
# Si no usas UKI, esto modificaría el archivo de configuración de tu grub/systemd-boot/etc.
HDR "Ajustando argumentos de inicialización del Kernel"
cmdline_file="/etc/kernel/cmdline.d/root.conf"

if [[ -f "$cmdline_file" ]]; then
    cmdline=$(cat "$cmdline_file")

    # Quitar 'splash' como token completo (respetando límites de palabra),
    # sin tocar parámetros que solo contengan "splash" como subcadena
    # (p. ej. splashscreen=1)
    read -ra tokens <<< "$cmdline"
    filtered=()
    for tok in "${tokens[@]}"; do
        [[ "$tok" == "splash" ]] || filtered+=("$tok")
    done

    # Inyección de flags optimizados
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
    # plymouth: Quita la pantalla de carga animada nativa de la RAM.
    # kms: Kernel Mode Setting temprano; al quitarlo se delega de forma directa y fluida al driver de video principal mas tarde
    for hook in plymouth kms; do
        if grep -qP "^HOOKS=.*\b${hook}\b" "$mkinitcpio_conf"; then
            # Cubre el hook precedido de espacio o de '(' (primer elemento del array)
            sed -i -E "/^HOOKS=/s/([([:space:]])${hook}([[:space:]])/\1\2/g; /^HOOKS=/s/([([:space:]])${hook}\)/\1)/g" "$mkinitcpio_conf"
            if grep -qP "^HOOKS=.*\b${hook}\b" "$mkinitcpio_conf"; then
                WRN "No se pudo eliminar el hook '${hook}' automáticamente, revísalo a mano"
            else
                OK "Hook '${hook}' eliminado para aligerar la carga en memoria inicial"
                needs_rebuild=1
            fi
        fi
    done
fi

# 3b. REGENERAR INITRAMFS/UKI SI HUBO CAMBIOS
# Sin este paso, los cambios de cmdline y HOOKS no se aplican al binario que
# realmente arranca (el UKI ya generado por el Módulo 1 quedó obsoleto).
if [[ $needs_rebuild -eq 1 ]]; then
    HDR "Regenerando initramfs/UKI con los cambios aplicados"
    if command -v mkinitcpio &>/dev/null && [[ -f /etc/mkinitcpio.d/linux-cachyos.preset ]]; then
        mkinitcpio -p linux-cachyos
        OK "initramfs/UKI regenerado"
    else
        WRN "No se encontró el preset de linux-cachyos; regenera el initramfs manualmente"
    fi
fi

# 4. ENMASCARADO DE SERVICIOS CRÍTICOS DE SYSTEMD
HDR "Deshabilitando servicios paralelos innecesarios"

# Servicios de Plymouth remanentes en el sistema operativo
plymouth_svcs=(plymouth-start.service plymouth-quit.service plymouth-quit-wait.service plymouth-read-write.service)
for svc in "${plymouth_svcs[@]}"; do
    if systemctl list-unit-files "$svc" 2>/dev/null | grep -q "$svc"; then
        systemctl disable "$svc" &>/dev/null || true
        systemctl mask "$svc" &>/dev/null
        OK "Enmascarado profundo: $svc"
    fi
done

# NetworkManager-wait-online: Este servicio frena la carga del escritorio/login
# hasta que el sistema tenga una IP asignada y conexión a internet verificada.
# Al enmascararlo, el sistema inicia instantáneamente y la red se conecta en segundo plano.
nm_wait="NetworkManager-wait-online.service"
if systemctl list-unit-files "$nm_wait" 2>/dev/null | grep -q "$nm_wait"; then
    systemctl disable "$nm_wait" &>/dev/null || true
    systemctl mask "$nm_wait" &>/dev/null
    OK "Enmascarado: $nm_wait (El login ya no esperará por internet)"
fi

HDR "Optimizaciones de rendimiento de software concluidas."
