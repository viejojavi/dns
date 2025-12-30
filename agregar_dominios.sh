#!/bin/bash

# Configuración
ZONES_DIR="/etc/bind/zones"
ZONES_FILE="/etc/bind/manual.conf"
NAMED_CONF="/etc/bind/named.conf.local"
IPV4_REDIRECT="38.188.178.250"
IPV6_REDIRECT="2803:b850:0:200::250"

mkdir -p "$ZONES_DIR"
touch "$ZONES_FILE"

# Asegurar inclusión del archivo manual.conf en named.conf.local
if ! grep -q "$ZONES_FILE" "$NAMED_CONF"; then
    echo "include \"$ZONES_FILE\";" >> "$NAMED_CONF"
    echo "✅ Se agregó include a named.conf.local"
fi

# Resultados
created=()
duplicates=()
errors=()

# Función para validar FQDN
valid_fqdn() {
    echo "$1" | grep -Pq '^(?!\-)([a-zA-Z0-9\-]{1,63}\.)+[a-zA-Z]{2,}$'
}

# Verificar si la zona ya está declarada en manual.conf
zone_exists() {
    grep -q "zone \"$1\"" "$ZONES_FILE"
}

# Crear archivo de zona directa
crear_zona_directa() {
    local dominio="$1"
    local file="$ZONES_DIR/db.$dominio"

    cat > "$file" <<EOF
\$TTL 86400
@   IN  SOA ns.$dominio. admin.$dominio. (
        $(date +%Y%m%d%H) ; Serial
        3600              ; Refresh
        1800              ; Retry
        604800            ; Expire
        86400 )           ; Minimum TTL

@       IN  NS    ns.$dominio.
ns      IN  A     $IPV4_REDIRECT
@       IN  A     $IPV4_REDIRECT
www     IN  A     $IPV4_REDIRECT
@       IN  AAAA  $IPV6_REDIRECT
www     IN  AAAA  $IPV6_REDIRECT
EOF

    echo "zone \"$dominio\" {
    type master;
    file \"$file\";
};" >> "$ZONES_FILE"
}

# Ingreso de FQDNs
while true; do
    read -rp "Ingrese un dominio FQDN (o 'fin' para terminar): " fqdn

    [[ "$fqdn" == "fin" ]] && break

    if ! valid_fqdn "$fqdn"; then
        echo "❌ Dominio inválido: $fqdn"
        errors+=("$fqdn (FQDN inválido)")
        continue
    fi

    if zone_exists "$fqdn"; then
        echo "⚠️  Zona ya existe: $fqdn"
        duplicates+=("$fqdn")
        continue
    fi

    echo "✅ Generando zona para $fqdn..."

    crear_zona_directa "$fqdn"

    # Validar sintaxis
    if ! named-checkzone "$fqdn" "$ZONES_DIR/db.$fqdn" > /dev/null 2>&1; then
        echo "❌ Error en sintaxis de la zona $fqdn"
        errors+=("$fqdn (Error sintaxis)")
        continue
    fi

    created+=("$fqdn")
done

# Resumen
echo -e "\n📋 Resumen final:"
echo "Zonas creadas: ${#created[@]}"
for d in "${created[@]}"; do echo "  ✔ $d"; done

echo "Zonas duplicadas: ${#duplicates[@]}"
for d in "${duplicates[@]}"; do echo "  ⚠ $d"; done

echo "Zonas con errores: ${#errors[@]}"
for d in "${errors[@]}"; do echo "  ❌ $d"; done

# Recargar BIND si hubo cambios
if [[ ${#created[@]} -gt 0 ]]; then
    systemctl reload bind9 && echo "🔁 BIND recargado exitosamente."
fi
