#!/bin/bash

# ==============================================================================
# Instalador DNS Recursivo PRO - Configuración Integral (Header + DNS + Cron)
# ==============================================================================

set -e

if [[ $EUID -ne 0 ]]; then
   echo "[-] Este script debe ejecutarse como root (sudo)." 
   exit 1
fi

echo "========================================================"
echo "    INSTALACIÓN Y AUTOMATIZACIÓN DNS RECURSIVO"
echo "========================================================"

# --- 1. Preparación e Instalación ---
apt update && apt install -y bind9 bind9utils curl dnsutils cron update-notifier-common

# --- 2. Configuración del Header del Sistema (MOTD) ---
URL_HEADER="https://raw.githubusercontent.com/viejojavi/header/refs/heads/main/00-header"
HEADER_PATH="/etc/update-motd.d/00-header"

echo "[*] Configurando header del sistema personalizado..."
# Eliminamos headers por defecto para que solo resalte el tuyo
chmod -x /etc/update-motd.d/* 2>/dev/null || true

if curl -s -f "$URL_HEADER" -o "$HEADER_PATH"; then
    chown root:root "$HEADER_PATH"
    chmod +x "$HEADER_PATH"
    ESTADO_HEADER="[✓] OK"
else
    ESTADO_HEADER="[!] FALLO"
fi

# --- 3. Configuración de BIND9 (GitHub) ---
CONF_OPTIONS="/etc/bind/named.conf.options"
URL_OPTIONS="https://raw.githubusercontent.com/viejojavi/dns/refs/heads/main/named.conf.options"

echo "[*] Descargando named.conf.options..."
if curl -s -f "$URL_OPTIONS" -o "$CONF_OPTIONS"; then
    chown root:bind "$CONF_OPTIONS"
    chmod 644 "$CONF_OPTIONS"
    ESTADO_CONF="[✓] OK"
else
    ESTADO_CONF="[!] FALLO"
fi

# --- 4. Sincronización de Root Servers (IANA) ---
ROOT_HINTS_FILE="/etc/bind/db.root"
URL_IANA_ROOT="https://www.internic.net/domain/named.root"

echo "[*] Sincronizando Root Servers con IANA..."
curl -s -f "$URL_IANA_ROOT" -o "$ROOT_HINTS_FILE" && ESTADO_ROOT="[✓] OK" || ESTADO_ROOT="[!] FALLO"
chown root:bind "$ROOT_HINTS_FILE" 2>/dev/null || true

# --- 5. Configuración de resolv.conf (Inmutable) ---
URL_RESOLV="https://raw.githubusercontent.com/viejojavi/dns/refs/heads/main/resolv.conf"
RESOLV_FILE="/etc/resolv.conf"

echo "[*] Aplicando resolv.conf inmutable..."
chattr -i $RESOLV_FILE 2>/dev/null || true
rm -f $RESOLV_FILE
if curl -s -f "$URL_RESOLV" -o "$RESOLV_FILE"; then
    chmod 644 "$RESOLV_FILE"
    chattr +i "$RESOLV_FILE"
    ESTADO_RESOLV="[✓] OK (Inmutable)"
else
    ESTADO_RESOLV="[!] FALLO"
fi

# --- 6. Tarea Cron Mensual ---
CRON_SCRIPT="/usr/local/bin/update-dns-roots.sh"
echo "0 0 1 * * root curl -s -f $URL_IANA_ROOT -o $ROOT_HINTS_FILE && systemctl reload named" > /etc/cron.d/update-dns-root-hints
systemctl restart cron

# --- 7. Reinicio de Servicio BIND ---
echo "[*] Reiniciando BIND9..."
systemctl unmask named.service 2>/dev/null || true
systemctl daemon-reload
systemctl enable named.service
systemctl restart named.service

# --- 8. Pruebas de Resolución ---
sleep 3
dig @127.0.0.1 . NS +short | grep -q "root-servers.net" && ESTADO_RES_ROOT="[✓] ACTIVA" || ESTADO_RES_ROOT="[!] ERROR"
dig @127.0.0.1 google.com +short > /dev/null && ESTADO_RES_EXT="[✓] ACTIVA" || ESTADO_RES_EXT="[!] BLOQUEADA"

# --- 9. CHECKLIST DE OPERATIVIDAD ---
echo -e "\n========================================================"
echo "          CHECKLIST DE FUNCIONES GENERADAS"
echo "========================================================"
echo "  1. Header del Sistema:           $ESTADO_HEADER"
echo "  2. Configuración BIND (GitHub):  $ESTADO_CONF"
echo "  3. Sincronización IANA:          $ESTADO_ROOT"
echo "  4. Archivo resolv.conf:          $ESTADO_RESOLV"
echo "  5. Tarea Cron Mensual:           [✓] INSTALADO"
echo "  6. Servicio BIND (named):        [✓] REINICIADO"
echo "  7. Resolución Raíz (.):          $ESTADO_RES_ROOT"
echo "  8. Resolución Externa (Recurs):  $ESTADO_RES_EXT"
echo "--------------------------------------------------------"
echo "  Header: /etc/update-motd.d/00-header"
echo "  Nota: Para ver el nuevo header, cierre sesión y vuelva a entrar."
echo "========================================================"
