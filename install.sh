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
validation_errors=0

# Función para limpieza inicial
cleanup_environment() {
    printf "${YELLOW}Realizando limpieza inicial...${NC}\n"
    
    # Limpiar archivos de configuración
    for config in "${CONFIG_FILES[@]}"; do
        sudo rm -f "/etc/bind/${config}.conf"
        sudo touch "/etc/bind/${config}.conf"
        sudo chown root:bind "/etc/bind/${config}.conf"
        printf "${GREEN}Archivo de configuración listo: /etc/bind/${config}.conf${NC}\n"
    done
    
    # Limpiar directorio de zonas
    sudo rm -f "${ZONE_DIR}"/db.*
    
    # Crear directorio temporal
    mkdir -p "$TEMP_DIR"
}

# Barra de progreso animada con porcentaje
progress_bar() {
    local pid=$1
    local message=$2
    local total=$3
    local delay=0.1
    local spin_chars=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
    local i=0
    local count=0
    
    printf "${CYAN}${message} ${spin_chars[$i]} [0%%]${NC}"
    
    while kill -0 "$pid" 2>/dev/null; do
        i=$(( (i+1) % 10 ))
        if [ -n "$total" ] && [ "$total" -gt 0 ]; then
            count=$(ls "${ZONE_DIR}"/db.* 2>/dev/null | wc -l)
            percent=$((count * 100 / total))
            percent=$((percent > 100 ? 100 : percent))
            printf "\r${CYAN}${message} ${spin_chars[$i]} [%3d%%]${NC}" "$percent"
        else
            printf "\r${CYAN}${message} ${spin_chars[$i]}${NC}"
        fi
        sleep "$delay"
    done
    
    printf "\r${GREEN}${message} ✓ [100%%]${NC}\n"
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
    
    # Agregar al archivo de configuración correspondiente
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

# Función para verificar archivos locales
check_local_files() {
    printf "${BLUE}Verificando archivos locales...${NC}\n"
    local missing_files=0
    
    for file in "${LOCAL_FILES[@]}"; do
        if [ ! -f "$file" ]; then
            printf "${RED}Error: Archivo local requerido no encontrado: ${file}${NC}\n"
            ((missing_files++))
        else
            printf "${GREEN}Archivo local encontrado: ${file}${NC}\n"
            # Verificar que el archivo no esté vacío
            if [ ! -s "$file" ]; then
                printf "${YELLOW}Advertencia: El archivo ${file} está vacío${NC}\n"
            fi
        fi
    done
    
    if [ $missing_files -gt 0 ]; then
        printf "${RED}Error: Faltan archivos locales requeridos. Abortando.${NC}\n"
        exit 1
    fi
}

# Función para descargar magis.txt con validación
download_magis_file() {
    printf "${BLUE}Descargando magis.txt desde GitHub...${NC}\n"
    
    local http_status=$(curl -s -o "${TEMP_DIR}/magis_source.txt" -w "%{http_code}" "$GITHUB_MAGIS_URL")
    
    if [ "$http_status" -ne 200 ]; then
        printf "${RED}Error: No se pudo descargar magis.txt (HTTP $http_status)${NC}\n"
        exit 1
    fi
    
    if [ ! -s "${TEMP_DIR}/magis_source.txt" ]; then
        printf "${RED}Error: El archivo magis.txt descargado está vacío${NC}\n"
        exit 1
    fi
    
    printf "${GREEN}magis.txt descargado correctamente (%s líneas)${NC}\n" "$(wc -l < "${TEMP_DIR}/magis_source.txt")"
}

# Función para procesar archivos de dominios
process_domain_file() {
    local file=$1
    local config=$2
    local domains=()
    
    printf "\n${BLUE}=== Procesando dominios para ${config} ===${NC}\n"
    
    # Obtener dominios según la fuente
    if [ "$config" == "magis" ]; then
        download_magis_file
        input_file="${TEMP_DIR}/magis_source.txt"
    else
        if [ ! -f "$file" ]; then
            printf "${RED}Error: Archivo local $file no encontrado para $config${NC}\n"
            return 1
        fi
        input_file="$file"
        printf "${GREEN}Procesando archivo local: ${file} (%s líneas)${NC}\n" "$(wc -l < "$file")"
    fi
    
    # Contador para este archivo específico
    local file_processed=0
    local file_skipped=0
    
    # Procesar cada línea del archivo
    while IFS= read -r line; do
        # Eliminar espacios en blanco y comentarios
        line=$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/#.*$//')
        [ -z "$line" ] && continue
        
        domain=$(extract_domain "$line")
        
        if [ -z "$domain" ]; then
            skipped_domains["$line"]=1
            ((total_skipped++))
            ((file_skipped++))
            continue
        fi
        
        if create_zone "$domain" "$config"; then
            processed_domains["$domain"]=1
            ((total_processed++))
            ((file_processed++))
        fi
    done < "$input_file"
    
    printf "${GREEN}${config}: Procesados ${file_processed} dominios | Omitidos ${file_skipped}${NC}\n"
}

# Configurar named.conf.local con zonas inversas
configure_named_conf() {
    printf "\n${MAGENTA}Configurando named.conf.local...${NC}\n"
    
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
    
    printf "${GREEN}Archivos de configuración creados:${NC}\n"
    for config in "${CONFIG_FILES[@]}"; do
        printf "  - /etc/bind/${config}.conf (%s zonas)\n" "$(grep -c "zone " "/etc/bind/${config}.conf")"
    done
}

# Crear zonas inversas básicas
create_reverse_zones() {
    printf "\n${YELLOW}Creando zonas inversas...${NC}\n"
    
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
    
    printf "${GREEN}Zonas inversas creadas en ${ZONE_DIR}${NC}\n"
}

# Validación de zonas DNS con barra de progreso
validate_zones() {
    printf "\n${UNDERLINE}${BOLD}Validando zonas DNS:${NC}\n"
    local total_zones=$(( ${#created_zones[@]} + 2 )) # +2 para zonas inversas
    local current=0
    validation_errors=0
    
    # Archivo temporal para errores
    local error_log="${TEMP_DIR}/validation_errors.log"
    > "$error_log"
    
    # Función de fondo para validación
    validate_in_background() {
        # Validar zonas directas
        for domain in "${!created_zones[@]}"; do
            if ! sudo named-checkzone "$domain" "${ZONE_DIR}/db.${domain}" >> "$error_log" 2>&1; then
                ((validation_errors++))
            fi
            ((current++))
        done
        
        # Validar zonas inversas
        local reverse_zones=("178.188.38.in-addr.arpa" "0.0.0.0.0.0.0.0.0.0.0.0.0.2.0.0.0.0.0.5.8.b.3.0.8.2.ip6.arpa")
        for reverse in "${reverse_zones[@]}"; do
            if ! sudo named-checkzone "$reverse" "${ZONE_DIR}/db.${reverse%%.*}" >> "$error_log" 2>&1; then
                ((validation_errors++))
            fi
            ((current++))
        done
    }
    
    # Ejecutar validación en segundo plano
    validate_in_background &
    local bg_pid=$!
    
    # Mostrar barra de progreso
    while kill -0 "$bg_pid" 2>/dev/null; do
        local percent=$((current * 100 / total_zones))
        percent=$((percent > 100 ? 100 : percent))
        printf "\r${CYAN}Validando zonas... [%3d%%]${NC}" "$percent"
        sleep 0.1
    done
    
    printf "\r${GREEN}Validación completada: [100%%]${NC}\n"
    
    # Mostrar resumen de validación
    if [ $validation_errors -gt 0 ]; then
        printf "${RED}Se encontraron ${validation_errors} errores de validación${NC}\n"
        printf "${YELLOW}Detalles en: ${error_log}${NC}\n"
    else
        printf "${GREEN}Todas las zonas se validaron correctamente${NC}\n"
    fi
    
    return $validation_errors
}

# Mostrar resumen detallado
show_summary() {
    printf "\n${UNDERLINE}${BOLD}Resumen de ejecución:${NC}\n"
    printf "${GREEN}Dominios procesados: %d${NC}\n" "$total_processed"
    printf "${YELLOW}Dominios omitidos: %d${NC}\n" "$total_skipped"
    printf "${RED}Duplicados detectados: %d${NC}\n" "$total_duplicates"
    printf "${BLUE}Zonas creadas: %d${NC}\n" "$total_created"
    printf "${MAGENTA}Errores de validación: %d${NC}\n" "$validation_errors"
    
    printf "\n${UNDERLINE}${BOLD}Detalles por archivo:${NC}\n"
    printf "${CYAN}magis.txt: %d dominios procesados${NC}\n" "$(grep -c "zone " "/etc/bind/magis.conf")"
    printf "${CYAN}mintic.txt: %d dominios procesados${NC}\n" "$(grep -c "zone " "/etc/bind/mintic.conf")"
    printf "${CYAN}coljuegos.txt: %d dominios procesados${NC}\n" "$(grep -c "zone " "/etc/bind/coljuegos.conf")"
    
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
    
    # Verificar archivos locales primero
    check_local_files
    
    # Inicialización
    cleanup_environment
    sudo mkdir -p "$ZONE_DIR"
    sudo chown -R bind:bind "$ZONE_DIR"
    
    # Procesar cada archivo de configuración
    for config in "${CONFIG_FILES[@]}"; do
        if [ "$config" == "magis" ]; then
            process_domain_file "" "$config"
        else
            process_domain_file "${config}.txt" "$config"
        fi
    done
    
    # Configuración final
    configure_named_conf
    create_reverse_zones
    
    # Recargar configuración
    printf "\n${MAGENTA}Recargando configuración de BIND9...${NC}\n"
    sudo rndc reload >/dev/null 2>&1 &
    progress_bar $! "Aplicando cambios" "${#created_zones[@]}"
    
    # Validación y resumen
    validate_zones
    show_summary
    
    # Limpieza final
    rm -rf "$TEMP_DIR"
    
    printf "\n${BOLD}${GREEN}=== CONFIGURACIÓN COMPLETADA ===${NC}\n"
    printf "${YELLOW}Nota: Todos los dominios redirigen a ${IPV4_ADDRESS} (IPv4) y ${IPV6_ADDRESS} (IPv6)${NC}\n"
    
    exit $validation_errors
}

# Ejecutar
main
