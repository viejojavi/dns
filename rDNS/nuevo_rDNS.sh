#!/bin/bash

# ==============================================================================
# BIND rDNS Manager con Validación de Resolución
# ==============================================================================

set -e

# --- 1. Verificación de Privilegios ---
if [[ $EUID -ne 0 ]]; then
   echo "[-] Este script debe ejecutarse como root (sudo)." 
   exit 1
fi

# --- 2. Rutas y Limpieza Inicial ---
CONF_LOCAL="/etc/bind/named.conf.local"
CONF_REVERSE="/etc/bind/named.conf.reverse"
ZONES_DIR="/etc/bind/zones"
mkdir -p "$ZONES_DIR"

# Limpieza total para evitar el error "expected near 'el'"
echo "// Archivo de zonas reversas - Generado automáticamente" > "$CONF_REVERSE"

# --- 3. Funciones de Cálculo ---
obtener_zona_arpa_v4() {
    echo "$1" | cut -d/ -f1 | awk -F. '{print $3"."$2"."$1".in-addr.arpa"}'
}

obtener_zona_arpa_v6() {
    local prefix=$(echo "$1" | cut -d/ -f2)
    local nibbles_count=$((prefix / 4))
    python3 -c "import ipaddress; ip = ipaddress.ip_network('$1').network_address.exploded.replace(':', ''); print('.'.join(ip[:$nibbles_count][::-1]) + '.ip6.arpa')"
}

# --- 4. Recolección de Datos ---
read -rp "[?] Dominio (ej. reintech.com): " dominio
read -rp "[?] Email admin: " email
read -rp "[?] Nombre NS (ej. ns1): " ns_prefix

echo "[*] Ingrese los bloques IPv4 (ej: 38.191.213.0/24):"
read -ra bloques_ipv4
echo "[*] Ingrese los bloques IPv6 (ej: 2803:77d0::/32):"
read -ra bloques_ipv6

# --- 5. Configuración de named.conf ---
if ! grep -q "$CONF_REVERSE" "$CONF_LOCAL"; then
    echo "include \"$CONF_REVERSE\";" >> "$CONF_LOCAL"
fi

for bloque in "${bloques_ipv4[@]}"; do
    zona_nom=$(obtener_zona_arpa_v4 "$bloque")
    cat <<EOF >> "$CONF_REVERSE"
zone "$zona_nom" { type master; file "$ZONES_DIR/db.reverse"; };
EOF
done

for bloque in "${bloques_ipv6[@]}"; do
    zona_nom=$(obtener_zona_arpa_v6 "$bloque")
    cat <<EOF >> "$CONF_REVERSE"
zone "$zona_nom" { type master; file "$ZONES_DIR/db.reverse"; };
EOF
done

# --- 6. Gestión de Seriales y SOA ---
archivo_directo="$ZONES_DIR/db.$dominio"
archivo_reverso="$ZONES_DIR/db.reverse"

obtener_nuevo_serial() {
    local hoy=$(date +%Y%m%d)
    local s_act=$(grep -oP '\d{10}(?=\s*;serial)' "$1" 2>/dev/null || true)
    [[ "$s_act" =~ ^$hoy ]] && echo $((s_act + 1)) || echo "${hoy}01"
}

sd=$(obtener_nuevo_serial "$archivo_directo")
sr=$(obtener_nuevo_serial "$archivo_reverso")

for f in "$archivo_directo" "$archivo_reverso"; do
    ser=$([[ "$f" == "$archivo_directo" ]] && echo "$sd" || echo "$sr")
    cat <<EOF > "$f"
\$TTL 300
@ IN SOA $ns_prefix.$dominio. ${email//@/.}. ( $ser ;serial
    3600 600 2419200 300 )
@ IN NS $ns_prefix.$dominio.
EOF
done

# --- 7. Ingreso de Registros y Almacenamiento ---
declare -A lista_pruebas
echo -e "\n--- Configuración de Registros PTR ---"
while true; do
    read -rp "Subdominio (ENTER para finalizar): " sub
    [[ -z "$sub" ]] && break
    read -rp "IP para $sub.$dominio: " ip
    
    lista_pruebas["$ip"]="$sub.$dominio."
    fqdn="$sub.$dominio."
    
    if [[ "$ip" =~ : ]]; then
        nibbles=$(python3 -c "import ipaddress; print('.'.join(ipaddress.ip_address('$ip').exploded.replace(':', '')[::-1]))")
        echo "${nibbles}.ip6.arpa. IN PTR $fqdn" >> "$archivo_reverso"
        echo "$sub IN AAAA $ip" >> "$archivo_directo"
    else
        rev_v4=$(echo "$ip" | awk -F. '{print $4"."$3"."$2"."$1".in-addr.arpa."}')
        echo "$rev_v4 IN PTR $fqdn" >> "$archivo_reverso"
        echo "$sub IN A $ip" >> "$archivo_directo"
    fi
done

# --- 8. Aplicación de Permisos y Reinicio ---
chown -R bind:bind "$ZONES_DIR" "$CONF_REVERSE"
chmod 644 "$CONF_REVERSE"

echo -e "\n[*] Validando y reiniciando BIND9..."
if named-checkconf /etc/bind/named.conf; then
    systemctl restart bind9
    sleep 2 # Tiempo para que BIND cargue las zonas en memoria
    
    # --- 9. RESULTADO DE LA RESOLUCIÓN ---
    echo -e "\n========================================================"
    echo -e "       REPORTE DE RESOLUCIÓN INVERSA (rDNS)"
    echo -e "========================================================"
    printf "%-25s %-25s %-10s\n" "IP" "ESPERADO" "ESTADO"
    echo "--------------------------------------------------------"

    for ip_test in "${!lista_pruebas[@]}"; do
        esperado="${lista_pruebas[$ip_test]}"
        # Consulta local forzada al servidor que acabamos de configurar
        resultado=$(dig @127.0.0.1 -x "$ip_test" +short | sed 's/\.$//' || echo "FALLO")
        
        # Limpiar el punto final del FQDN para comparar
        esperado_limpio=$(echo "$esperado" | sed 's/\.$//')

        if [[ "$resultado" == "$esperado_limpio" ]]; then
            printf "%-25s %-25s [ CORRECTO ]\n" "$ip_test" "$esperado_limpio"
        else
            printf "%-25s %-25s [ FALLIDO ]\n" "$ip_test" "$esperado_limpio"
            echo "    -> Obtenido: $resultado"
        fi
    done
    echo "========================================================"
else
    echo -e "\n[!] ERROR: La configuración tiene errores de sintaxis."
    named-checkconf -z /etc/bind/named.conf | grep "error"
    exit 1
fi
