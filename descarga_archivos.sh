#!/bin/bash

set -euo pipefail

#########################################
# CONFIGURACIÓN
#########################################

URL_MINTIC="https://portal-de-bloqueo-ley-679-de-2001-431043877423.us-west2.run.app/api/protected-docs/file1/raw"
URL_COLJUEGOS="https://portal-de-bloqueo-ley-679-de-2001-431043877423.us-west2.run.app/api/protected-docs/file2/raw"

ARCHIVO_MINTIC="mintic.txt"
ARCHIVO_COLJUEGOS="coljuegos.txt"

ARCHIVO_DOMINIOS="dominios_mintic.txt"

LOG_FILE="./descarga_dominios.log"

#########################################
# LOGGING
#########################################

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

#########################################
# DESCARGA
#########################################

descargar_archivos() {

    log "Iniciando descarga de archivos."

    wget \
        --timeout=30 \
        --tries=3 \
        -q \
        "$URL_MINTIC" \
        -O "$ARCHIVO_MINTIC"

    if [[ ! -s "$ARCHIVO_MINTIC" ]]; then
        log "ERROR: $ARCHIVO_MINTIC vacío o inválido."
        return 1
    fi

    log "Archivo descargado correctamente: $ARCHIVO_MINTIC"

    wget \
        --timeout=30 \
        --tries=3 \
        -q \
        "$URL_COLJUEGOS" \
        -O "$ARCHIVO_COLJUEGOS"

    if [[ ! -s "$ARCHIVO_COLJUEGOS" ]]; then
        log "ERROR: $ARCHIVO_COLJUEGOS vacío o inválido."
        return 1
    fi

    log "Archivo descargado correctamente: $ARCHIVO_COLJUEGOS"

    log "Descarga completada correctamente."

    return 0
}

#########################################
# EXTRAER DOMINIO
#########################################

extraer_dominio() {

    local url="$1"

    dominio=$(echo "$url" \
        | tr '[:upper:]' '[:lower:]' \
        | sed -E 's#https?://##' \
        | sed -E 's#^www\.##' \
        | cut -d/ -f1 \
        | cut -d: -f1 \
        | cut -d'?' -f1 \
        | cut -d'#' -f1)

    if [[ "$dominio" =~ ^([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}$ ]]; then
        echo "$dominio"
    fi
}

#########################################
# EXTRAER DOMINIOS
#########################################

extraer_dominios() {

    log "Extrayendo dominios."

    > "$ARCHIVO_DOMINIOS"

    cat "$ARCHIVO_MINTIC" "$ARCHIVO_COLJUEGOS" \
        | sed '/^\s*$/d' \
        | sed '/^\s*#/d' \
        | while read -r linea; do

            dominio=$(extraer_dominio "$linea")

            [[ -n "$dominio" ]] && echo "$dominio"

        done \
        | sort -u \
        > "$ARCHIVO_DOMINIOS"

    TOTAL=$(wc -l < "$ARCHIVO_DOMINIOS")

    log "Extracción finalizada."

    log "Total dominios únicos encontrados: $TOTAL"

    return 0
}

#########################################
# MOSTRAR RESUMEN
#########################################

mostrar_resumen() {

    echo
    echo "========================================"
    echo "        RESUMEN DE EJECUCIÓN"
    echo "========================================"
    echo
    echo "Archivo MINTIC:      $ARCHIVO_MINTIC"
    echo "Archivo COLJUEGOS:   $ARCHIVO_COLJUEGOS"
    echo "Salida dominios:     $ARCHIVO_DOMINIOS"
    echo
    echo "Total dominios únicos:"
    wc -l "$ARCHIVO_DOMINIOS"
    echo
    echo "Primeros 10 dominios:"
    head "$ARCHIVO_DOMINIOS"
    echo
    echo "Log:"
    echo "$LOG_FILE"
    echo
}

#########################################
# MAIN
#########################################

main() {

    log "===== INICIO SCRIPT ====="

    descargar_archivos

    extraer_dominios

    mostrar_resumen

    log "===== SCRIPT FINALIZADO ====="
}

main
