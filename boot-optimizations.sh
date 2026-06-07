#!/usr/bin/env bash
# ================================================================
# MÓDULO 2: Optimizaciones críticas de arranque y depuración
# ================================================================

set -euo pipefail

OK()  { echo -e "\033[0;32m  ✔  \033[0m$*"; }
WRN() { echo -e "\033[1;33m  ⚠  \033[0m$*"; }
HDR() { echo -e "\n\033[1;033[0;36m══════  $* ══════\033[0m"; }

[[ $EUID -eq 0 ]] || { echo "Ejecuta como root"; exit 1; }

# 1. PURGA DE KERNELS INNECESARIOS (Aceleración de compilaciones futuras)
HDR "Evaluando Kernel LTS"
lts_pkgs=()
for pkg in linux-cachyos-lts linux-cachyos-lts-headers; do
    pacman -Qi "$pkg" &>/dev/null && lts_pkgs+=("$pkg")
done

if [ ${#lts_pkgs[@]} -gt 0 ]; then
    pacman -Rs --noconfirm "${lts_pkgs[@]}" && OK "Kernel LTS removido"
    rm -f /boot/initramfs-linux-cachyos-lts.img /boot/initramfs-linux-cachyos-lts-fallback.img
else
    OK "No se detectó kernel LTS secundario"
fi

# 2. OPTIMIZACIÓN DE PARAMETROS DE KERNEL (CMDLINE)
# Si no usas UKI, esto modificaría el archivo de configuración de tu grub/systemd-boot/etc.
HDR "Ajustando argumentos de inicialización del Kernel"
cmdline_file="/etc/kernel/cmdline.d/root.conf"

if [[ -f "$cmdline_file" ]]; then
    cmdline=$(cat "$cmdline_file")
    
    # Quitar animaciones (Plymouth) para acelerar el salto a modo gráfico real
    cmdline="${cmdline/ splash/}"
    cmdline="${cmdline/splash /}"

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
        if ! echo "$cmdline" | grep -q "$key"; then
            cmdline="$cmdline ${opts[$key]}"
        fi
    done
    echo "$cmdline" | tr -s ' ' | sed 's/^ //;s/ $//' > "$cmdline_file"
    OK "Parámetros aplicados en cmdline: $(cat "$cmdline_file")"
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
            sed -i "/^HOOKS=/s/[[:space:]]\+${hook}//g" "$mkinitcpio_conf"
            OK "Hook '${hook}' eliminado para aligerar la carga en memoria inicial"
        fi
    done
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
