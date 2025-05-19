#!/bin/bash

#######################################################
# CONFIGURACIÓN GENERAL
#######################################################

# Ruta del archivo principal de configuración de BIND
ARCHIVO_CONFIG="/etc/bind/named.conf.local"

# Directorio para almacenar archivos de zona
DIR_ZONAS="/etc/bind/zones"

# Directorio base de configuración
DIR_CONFIG="/etc/bind"

# IPs de redirección
IP_REDIR="38.188.178.250"
IPV6_REDIR="2803:b850:0:200::250"

# Configuración de dominios NS y administrativo
DOM_NS="ns1.ticcol.com."
DOM_ADMIN="admin.ticcol.com."

# Archivos de log y backups
LOG_FILE="/var/log/dns_manager.log"
ERROR_LOG="/var/log/dns_errors.log"
BACKUP_DIR="/etc/bind/backups"
GITHUB_BACKUP_DIR="/etc/bind/github_backups"
DIR_OMITIDOS="/etc/bind/omitidos"

# Listas de configuración para procesar
declare -A CONFIG_LISTAS=(
    ["coljuegos"]="coljuegos.txt /tmp/coljuegos.tmp ${DIR_CONFIG}/coljuegos.conf"
    ["mintic"]="dominios_mintic.txt /tmp/mintic.tmp ${DIR_CONFIG}/mintic.conf"
    ["magis"]="https://raw.githubusercontent.com/viejojavi/dns/main/magis.txt /tmp/magis.tmp ${DIR_CONFIG}/magis.conf"
)

#######################################################
# FUNCIONES AUXILIARES
#######################################################

# Función para registrar mensajes en log
log() {
    local mensaje="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] ${mensaje}" | tee -a "$LOG_FILE"
}

# Función para validar existencia de una zona DNS
zona_existe() {
    local zona="$1"
    grep -q "zone \"$zona\"" "$ARCHIVO_CONFIG"
    return $?
}

# Función para verificar includes existentes
include_existe() {
    local archivo_include="$1"
    grep -q "include \"$archivo_include\"" "$ARCHIVO_CONFIG"
    return $?
}

# Función para verificar dependencias necesarias
verificar_dependencias() {
    local dependencias=("curl" "named-checkconf" "named-checkzone" "systemctl" "sort" "awk" "sed")
    for dep in "${dependencias[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            log "ERROR: La dependencia '$dep' no está instalada"
            exit 1
        fi
    done
}

#######################################################
# FUNCIONES PRINCIPALES
#######################################################

# Crear estructura de directorios necesarios
crear_estructura() {
    mkdir -p "$DIR_ZONAS" "$BACKUP_DIR" "$GITHUB_BACKUP_DIR" "$DIR_OMITIDOS" || {
        log "ERROR: No se pudo crear directorios"
        exit 1
    }
    
    chown -R bind:bind "$DIR_ZONAS" "$BACKUP_DIR" "$GITHUB_BACKUP_DIR" "$DIR_OMITIDOS"
    chmod 755 "$DIR_ZONAS" "$DIR_OMITIDOS"
    
    touch "$LOG_FILE" "$ERROR_LOG"
    chown bind:bind "$LOG_FILE" "$ERROR_LOG"
}

# Crear archivo de zona DNS
crear_zona() {
    local dominio="$1"
    local archivo_zona="$2"
    local serial="$3"
    
    cat > "$archivo_zona" <<EOF
\$TTL 86400
@ IN SOA $DOM_NS $DOM_ADMIN (
    $serial   ; Serial
    3600      ; Refresh
    1800      ; Retry
    604800    ; Expire
    86400 )   ; Minimum TTL
@ IN NS $DOM_NS
@ IN A $IP_REDIR
www IN A $IP_REDIR
@ IN AAAA $IPV6_REDIR
EOF
}

# Crear zonas de reverso para las IPs de redirección
crear_zonas_reverso_redireccion() {
    local serial=$(date +"%Y%m%d01")
    
    # Zona reversa IPv4
    local reversed_ipv4=$(echo "$IP_REDIR" | awk -F. '{print $4"."$3"."$2"."$1}')
    local archivo_reverso_ipv4="${DIR_ZONAS}/rev.ipv4.redirect"
    
    if ! zona_existe "${reversed_ipv4}.in-addr.arpa"; then
        cat > "$archivo_reverso_ipv4" <<EOF
\$TTL 86400
@ IN SOA $DOM_NS $DOM_ADMIN (
    $serial   ; Serial
    3600      ; Refresh
    1800      ; Retry
    604800    ; Expire
    86400 )   ; Minimum TTL
@ IN NS $DOM_NS
EOF

        echo "zone \"${reversed_ipv4}.in-addr.arpa\" {" >> "$ARCHIVO_CONFIG"
        echo "    type master;" >> "$ARCHIVO_CONFIG"
        echo "    file \"$archivo_reverso_ipv4\";" >> "$ARCHIVO_CONFIG"
        echo "};" >> "$ARCHIVO_CONFIG"
        log "Zona reversa IPv4 creada: ${reversed_ipv4}.in-addr.arpa"
    fi

    # Zona reversa IPv6
    local ipv6_expanded=$(echo "$IPV6_REDIR" | sed 's/::/:0:0:/g; s/:$/:0/; s/^:/0:/')
    local reversed_ipv6=$(echo "$ipv6_expanded" | awk -F: '{
        for(i=NF;i>0;i--) {
            len=split($i,chars,"")
            for(j=len;j>0;j--) printf "%s.", chars[j]
        }
    }')
    local archivo_reverso_ipv6="${DIR_ZONAS}/rev.ipv6.redirect"
    
    if ! zona_existe "${reversed_ipv6}ip6.arpa"; then
        cat > "$archivo_reverso_ipv6" <<EOF
\$TTL 86400
@ IN SOA $DOM_NS $DOM_ADMIN (
    $serial   ; Serial
    3600      ; Refresh
    1800      ; Retry
    604800    ; Expire
    86400 )   ; Minimum TTL
@ IN NS $DOM_NS
EOF

        echo "zone \"${reversed_ipv6}ip6.arpa\" {" >> "$ARCHIVO_CONFIG"
        echo "    type master;" >> "$ARCHIVO_CONFIG"
        echo "    file \"$archivo_reverso_ipv6\";" >> "$ARCHIVO_CONFIG"
        echo "};" >> "$ARCHIVO_CONFIG"
        log "Zona reversa IPv6 creada: ${reversed_ipv6}ip6.arpa"
    fi
}

# Validación detallada de dominios
validar_dominio() {
    local dominio="$1"
    
    # Expresiones regulares para validación
    local patron_valido='^([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'
    local patron_invalidos='[^a-zA-Z0-9.-]'
    local patron_guiones='--|^-|-$'
    local patron_tld='\.[a-zA-Z]{2,}$'

    [[ ! "$dominio" =~ $patron_valido ]] && echo "Formato general inválido" && return 1
    [[ "$dominio" =~ $patron_invalidos ]] && echo "Caracteres inválidos" && return 1
    [[ "$dominio" =~ $patron_guiones ]] && echo "Guiones incorrectos" && return 1
    [[ ! "$dominio" =~ $patron_tld ]] && echo "TLD inválido" && return 1

    return 0
}

# Procesar lista de dominios omitidos
procesar_omitidos() {
    local nombre_lista="$1"
    local archivo_omitidos="${DIR_OMITIDOS}/${nombre_lista}_omitidos.txt"
    local archivo_errores="${DIR_OMITIDOS}/${nombre_lista}_errores_$(date +%Y%m%d).csv"
    
    [ ! -s "$archivo_omitidos" ] && return 0

    log "Reprocesando dominios omitidos de $nombre_lista..."
    echo "Dominio,Error,Fecha Intento" > "$archivo_errores"
    
    local total=0 exitos=0 errores=0
    while IFS= read -r dominio; do
        ((total++))
        error_msg=$(validar_dominio "$dominio")
        
        if [ $? -eq 0 ]; then
            archivo_zona="${DIR_ZONAS}/db.${dominio}"
            if [ ! -f "$archivo_zona" ]; then
                crear_zona "$dominio" "$archivo_zona" $(date +"%Y%m%d01")
                chown bind:bind "$archivo_zona"
                ((exitos++))
            else
                echo "$dominio,Zona existente,$(date)" >> "$archivo_errores"
                ((errores++))
            fi
        else
            echo "$dominio,$error_msg,$(date)" >> "$archivo_errores"
            ((errores++))
        fi
    done < "$archivo_omitidos"

    log "Reprocesamiento completado: $exitos exitos, $errores errores"
    mv "$archivo_omitidos" "${archivo_omitidos}.procesado"
}

# Función principal de procesamiento de listas
procesar_lista() {
    local nombre_lista="$1"
    local fuente_datos="$2"
    local archivo_temporal="$3"
    local archivo_config_lista="$4"
    local archivo_omitidos="${DIR_OMITIDOS}/${nombre_lista}_omitidos.txt"

    log "Iniciando procesamiento de: $nombre_lista"
    
    # Descargar o copiar el archivo fuente
    if [[ "$fuente_datos" == http* ]]; then
        if ! curl -sSf --connect-timeout 60 "$fuente_datos" -o "$archivo_temporal"; then
            log "Error al descargar $fuente_datos"
            return 1
        fi
    else
        [ ! -f "$fuente_datos" ] && log "Archivo no encontrado: $fuente_datos" && return 1
        cp "$fuente_datos" "$archivo_temporal"
    fi

    # Preprocesamiento del archivo
    log "Limpiando y ordenando dominios..."
    sort -u "$archivo_temporal" | sed -e '/^#/d' -e '/^$/d' -e 's/[[:space:]]*//g' > "${archivo_temporal}.limpio"
    mv "${archivo_temporal}.limpio" "$archivo_temporal"

    # Variables de procesamiento
    local total_lineas=$(wc -l < "$archivo_temporal")
    local batch_size=500 contador=0 total=0 invalidos=0
    local temp_zonas=$(mktemp) dominios_procesados=$(mktemp)

    log "Procesando $total_lineas dominios..."
    while IFS= read -r url; do
        ((contador++))
        dominio=$(echo "$url" | tr '[:upper:]' '[:lower:]')
        
        # Validación del dominio
        if error_msg=$(validar_dominio "$dominio"); then
            # Verificar duplicados
            if ! grep -q "^${dominio}$" "$dominios_procesados"; then
                echo "$dominio" >> "$dominios_procesados"
                echo "zone \"$dominio\" { type master; file \"${DIR_ZONAS}/db.${dominio}\"; };" >> "$temp_zonas"
                [ ! -f "${DIR_ZONAS}/db.${dominio}" ] && crear_zona "$dominio" "${DIR_ZONAS}/db.${dominio}" $(date +"%Y%m%d01")
                ((total++))
            fi
        else
            ((invalidos++))
            echo "$dominio" >> "$archivo_omitidos"
            [[ $invalidos -le 10 ]] && log "Dominio inválido #$invalidos: $dominio ($error_msg)"
        fi

        # Reporte de progreso
        if (( contador % batch_size == 0 )); then
            porcentaje=$(( (contador * 100) / total_lineas ))
            log "Progreso: $contador/$total_lineas ($porcentaje%) - Válidos: $total"
            sleep 0.01
        fi
    done < "$archivo_temporal"

    # Generar archivo de configuración final
    echo "// Configuración generada automáticamente el $(date)" > "$archivo_config_lista"
    cat "$temp_zonas" >> "$archivo_config_lista"
    
    # Validar e incluir configuración
    if named-checkconf "$archivo_config_lista"; then
        if ! include_existe "$archivo_config_lista"; then
            echo "include \"$archivo_config_lista\";" >> "$ARCHIVO_CONFIG"
            log "Configuración de $nombre_lista añadida exitosamente"
        fi
    else
        log "Error en configuración de $nombre_lista"
        return 1
    fi

    # Procesar dominios omitidos
    procesar_omitidos "$nombre_lista"
    
    # Limpieza final
    rm -f "$temp_zonas" "$dominios_procesados" "$archivo_temporal"
    log "Procesamiento finalizado: $total válidos, $invalidos omitidos"
}

#######################################################
# EJECUCIÓN PRINCIPAL
#######################################################

main() {
    # Configuración inicial
    crear_estructura
    verificar_dependencias
    
    # Backup de configuración
    local backup_file="${BACKUP_DIR}/named.conf.local.$(date +%Y%m%d%H%M%S).bak"
    cp "$ARCHIVO_CONFIG" "$backup_file" || { log "Error al crear backup"; exit 1; }
    log "Backup creado: $backup_file"

    # Limpiar includes antiguos
    sed -i '/^include "\/etc\/bind\/.*\.conf";/d' "$ARCHIVO_CONFIG"

    # Crear zonas de reverso
    crear_zonas_reverso_redireccion

    # Procesar todas las listas
    for lista in "${!CONFIG_LISTAS[@]}"; do
        procesar_lista "$lista" ${CONFIG_LISTAS[$lista]}
    done

    # Validación final y reinicio
    if named-checkconf; then
        systemctl restart named && log "BIND reiniciado exitosamente" || log "Error al reiniciar BIND"
    else
        log "ERROR: Configuración DNS inválida"
        exit 1
    fi

    log "Proceso completado exitosamente"
}

# Punto de entrada principal
main
