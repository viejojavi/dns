#!/bin/bash

# Configuración global
PRIMARY_DOMAIN="ticcol.com"
PRIMARY_NS="ns1.${PRIMARY_DOMAIN}"
ADMIN_EMAIL="admin.${PRIMARY_DOMAIN}"
GITHUB_MAGIS_URL="https://raw.githubusercontent.com/viejojavi/dns/refs/heads/main/magis.txt"
LOCAL_FILES=("mintic.txt" "coljuegos.txt")
CONFIG_FILES=("magis" "mintic" "coljuegos")
ZONE_DIR="/etc/bind/zones"
DATE_SERIAL=$(date +"%y%m%d")
TEMP_DIR="/tmp/dns_config_$(date +%s)"
IPV4_ADDRESS="38.188.178.250"
IPV6_ADDRESS="2803:b850:0:200::250"

# Colores y formato
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'
UNDERLINE='\033[4m'

# Variables para estadísticas
declare -A processed_domains
declare -A skipped_domains
declare -A created_zones
declare -A unique_domains
total_processed=0
total_skipped=0
total_created=0
total_duplicates=0

# Función para limpieza inicial
cleanup_environment() {
    printf "${YELLOW}Realizando limpieza inicial...${NC}\n"
    
    # Limpiar archivos de configuración
    for config in "${CONFIG_FILES[@]}"; do
        sudo rm -f "/etc/bind/${config}.conf"
        sudo touch "/etc/bind/${config}.conf"
        sudo chown root:bind "/etc/bind/${config}.conf"
    done
    
    # Limpiar directorio de zonas
    sudo rm -f "${ZONE_DIR}"/db.*
    
    # Crear directorio temporal
    mkdir -p "$TEMP_DIR"
}

# Barra de progreso animada
progress_bar() {
    local pid=$1
    local message=$2
    local delay=0.1
    local spin_chars=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
    local i=0
    
    printf "${CYAN}${message} ${spin_chars[$i]}${NC}"
    
    while kill -0 "$pid" 2>/dev/null; do
        i=$(( (i+1) % 10 ))
        printf "\r${CYAN}${message} ${spin_chars[$i]}${NC}"
        sleep "$delay"
    done
    printf "\r${GREEN}${message} ✓${NC}\n"
}

# Función para extraer y limpiar dominio
extract_domain() {
    local input=$1
    
    # Eliminar protocolos http://, https:// y rutas
    local domain=$(echo "$input" | sed -e 's|^[hH][tT][tT][pP][sS]\?://||' -e 's|/.*$||' -e 's|:.*$||')
    
    # Eliminar subdominios no deseados (como www)
    domain=$(echo "$domain" | sed -e 's|^www\.||')
    
    # Eliminar puertos y parámetros
    domain=$(echo "$domain" | cut -d: -f1 | cut -d? -f1 | cut -d# -f1)
    
    # Convertir a minúsculas
    domain=$(echo "$domain" | tr '[:upper:]' '[:lower:]')
    
    # Validar dominio con regex mejorado
    if [[ "$domain" =~ ^([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
        echo "$domain"
    else
        echo ""
    fi
}

# Función para generar serial number
generate_serial() {
    local current_date=$(date +"%y%m%d")
    local counter="00"
    
    if [ -f "$1" ]; then
        local last_serial=$(grep -Po '\d{8}' "$1" | head -n1)
        if [[ "${last_serial:0:6}" == "$current_date" ]]; then
            counter=$((10#${last_serial:6:2} + 1))
            [ $counter -gt 99 ] && counter=99
            printf "%02d" $counter
            return
        fi
    fi
    echo "00"
}

# Función para crear zona DNS con redirección
create_zone() {
    local domain=$1
    local config=$2
    local zone_file="${ZONE_DIR}/db.${domain}"
    local serial="${DATE_SERIAL}$(generate_serial "$zone_file")"
    
    # Verificar duplicados
    if [ -n "${unique_domains[$domain]}" ]; then
        ((total_duplicates++))
        return 1
    fi
    unique_domains["$domain"]=1
    
    # Plantilla de zona DNS con redirección
    cat > "$zone_file" <<EOF
\$TTL 86400
@       IN      SOA     ${PRIMARY_NS}. ${ADMIN_EMAIL}. (
                        ${serial}      ; Serial
                        3600           ; Refresh
                        1800           ; Retry
                        604800         ; Expire
                        86400          ; Minimum TTL
                        )
@       IN      NS      ${PRIMARY_NS}.
@       IN      A       ${IPV4_ADDRESS}
@       IN      AAAA    ${IPV6_ADDRESS}
*       IN      A       ${IPV4_ADDRESS}
*       IN      AAAA    ${IPV6_ADDRESS}
EOF
    
    # Agregar al archivo de configuración
    cat >> "/etc/bind/${config}.conf" <<EOF
zone "${domain}" {
    type master;
    file "${ZONE_DIR}/db.${domain}";
};

EOF
    
    created_zones["$domain"]=1
    ((total_created++))
    return 0
}

# Función para procesar archivos de dominios
process_domain_file() {
    local file=$1
    local config=$2
    local domains=()
    
    printf "${BLUE}Procesando dominios para ${config}...${NC}\n"
    
    # Obtener dominios según la fuente
    if [ "$config" == "magis" ]; then
        curl -s "$GITHUB_MAGIS_URL" > "${TEMP_DIR}/magis_source.txt" &
        progress_bar $! "Descargando lista magis"
        input_file="${TEMP_DIR}/magis_source.txt"
    else
        input_file="$file"
    fi
    
    # Procesar cada línea del archivo
    while IFS= read -r line; do
        domain=$(extract_domain "$line")
        
        if [ -z "$domain" ]; then
            skipped_domains["$line"]=1
            ((total_skipped++))
            continue
        fi
        
        if create_zone "$domain" "$config"; then
            processed_domains["$domain"]=1
            ((total_processed++))
        fi
    done < "$input_file"
}

# Configurar named.conf.local con zonas inversas
configure_named_conf() {
    printf "${MAGENTA}Configurando named.conf.local...${NC}\n"
    
    cat > /etc/bind/named.conf.local <<EOF
// Zonas directas
include "/etc/bind/magis.conf";
include "/etc/bind/mintic.conf";
include "/etc/bind/coljuegos.conf";

// Zona inversa para ${IPV4_ADDRESS}
zone "178.188.38.in-addr.arpa" {
    type master;
    file "${ZONE_DIR}/db.178.188.38";
};

// Zona inversa para ${IPV6_ADDRESS}
zone "0.5.2.0.0.0.0.2.0.0.5.8.b.3.0.8.2.ip6.arpa" {
    type master;
    file "${ZONE_DIR}/db.2803b8500200";
};
EOF
}

# Crear zonas inversas básicas
create_reverse_zones() {
    printf "${YELLOW}Creando zonas inversas...${NC}\n"
    
    # Zona inversa IPv4
    cat > "${ZONE_DIR}/db.178.188.38" <<EOF
\$TTL 86400
@ IN SOA ${PRIMARY_NS}. ${ADMIN_EMAIL}. (
    ${DATE_SERIAL}01 ; Serial
    3600       ; Refresh
    1800       ; Retry
    604800     ; Expire
    86400      ; Minimum TTL
)
@ IN NS ${PRIMARY_NS}.
250 IN PTR ${PRIMARY_DOMAIN}.
EOF
    
    # Zona inversa IPv6
    cat > "${ZONE_DIR}/db.2803b8500200" <<EOF
\$TTL 86400
@ IN SOA ${PRIMARY_NS}. ${ADMIN_EMAIL}. (
    ${DATE_SERIAL}01 ; Serial
    3600       ; Refresh
    1800       ; Retry
    604800     ; Expire
    86400      ; Minimum TTL
)
@ IN NS ${PRIMARY_NS}.
0.0.0.0.0.0.0.0.0.0.0.0.0.0.2.5.0 IN PTR ${PRIMARY_DOMAIN}.
EOF
}

# Validación de zonas DNS
validate_zones() {
    local errors=0
    printf "\n${UNDERLINE}${BOLD}Validando zonas DNS:${NC}\n"
    
    # Validar zonas directas
    for domain in "${!created_zones[@]}"; do
        printf "${YELLOW}Validando ${domain}...${NC}"
        if sudo named-checkzone "$domain" "${ZONE_DIR}/db.${domain}" >/dev/null 2>&1; then
            printf " ${GREEN}✓${NC}\n"
        else
            printf " ${RED}✗${NC}\n"
            ((errors++))
        fi
    done
    
    # Validar zonas inversas
    for reverse in "178.188.38.in-addr.arpa" "0.0.0.0.0.0.0.0.0.0.0.0.0.2.0.0.0.0.0.5.8.b.3.0.8.2.ip6.arpa"; do
        printf "${YELLOW}Validando ${reverse}...${NC}"
        if sudo named-checkzone "$reverse" "${ZONE_DIR}/db.${reverse%%.*}" >/dev/null 2>&1; then
            printf " ${GREEN}✓${NC}\n"
        else
            printf " ${RED}✗${NC}\n"
            ((errors++))
        fi
    done
    
    return $errors
}

# Mostrar resumen detallado
show_summary() {
    printf "\n${UNDERLINE}${BOLD}Resumen de ejecución:${NC}\n"
    printf "${GREEN}Dominios procesados: %d${NC}\n" "$total_processed"
    printf "${YELLOW}Dominios omitidos: %d${NC}\n" "$total_skipped"
    printf "${RED}Duplicados detectados: %d${NC}\n" "$total_duplicates"
    printf "${BLUE}Zonas creadas: %d${NC}\n" "$total_created"
    
    printf "\n${UNDERLINE}${BOLD}Detalles de configuración:${NC}\n"
    printf "${CYAN}IP de redirección IPv4: ${IPV4_ADDRESS}${NC}\n"
    printf "${CYAN}IP de redirección IPv6: ${IPV6_ADDRESS}${NC}\n"
    printf "${CYAN}Servidor DNS principal: ${PRIMARY_NS}${NC}\n"
    
    printf "\n${GREEN}Ejemplos de dominios configurados:${NC}\n"
    printf "  - %s\n" "${!processed_domains[@]}" | sort | head -5
    [ "${#processed_domains[@]}" -gt 5 ] && printf "  - ... (mostrando 5 de %d)\n" "${#processed_domains[@]}"
}

# Función principal
main() {
    printf "${BOLD}${BLUE}=== CONFIGURADOR DNS AVANZADO ===${NC}\n\n"
    printf "${YELLOW}Configurando redirección a ${IPV4_ADDRESS} (IPv4) y ${IPV6_ADDRESS} (IPv6)${NC}\n\n"
    
    # Inicialización
    cleanup_environment
    sudo mkdir -p "$ZONE_DIR"
    sudo chown -R bind:bind "$ZONE_DIR"
    
    # Procesar cada archivo de configuración
    for config in "${CONFIG_FILES[@]}"; do
        if [ "$config" == "magis" ]; then
            process_domain_file "" "$config"
        else
            if [ -f "${config}.txt" ]; then
                process_domain_file "${config}.txt" "$config"
            else
                printf "${RED}Archivo ${config}.txt no encontrado. Omitiendo...${NC}\n"
            fi
        fi
    done
    
    # Configuración final
    configure_named_conf
    create_reverse_zones
    
    # Recargar configuración
    printf "\n${MAGENTA}Recargando configuración de BIND9...${NC}\n"
    sudo rndc reload >/dev/null 2>&1 &
    progress_bar $! "Aplicando cambios"
    
    # Validación y resumen
    validate_zones
    show_summary
    
    # Limpieza final
    rm -rf "$TEMP_DIR"
    
    printf "\n${BOLD}${GREEN}=== CONFIGURACIÓN COMPLETADA ===${NC}\n"
    printf "${YELLOW}Nota: Todos los dominios redirigen a ${IPV4_ADDRESS} (IPv4) y ${IPV6_ADDRESS} (IPv6)${NC}\n"
}

# Ejecutar
main
