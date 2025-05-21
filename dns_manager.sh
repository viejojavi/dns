#!/bin/bash

# ========================
# CONFIGURACION GENERAL
# ========================

BIND_DIR="/etc/bind"
ZONES_DIR="$BIND_DIR/zones"
TEMPLATE_FILE="$ZONES_DIR/template.db"
OMITIDOS="omitidos_final.txt"
DOMINIO_REDIRECCION="bloqueo.ticcol.com."
IPV4_REDIRECT="38.188.178.250"
IPV6_REDIRECT="2803:b850:0:200::250"
REV_IPV4_FILE="$ZONES_DIR/rev.ipv4.redirect"
REV_IPV6_FILE="$ZONES_DIR/rev.ipv6.redirect"

MAGIS_URL="https://raw.githubusercontent.com/viejojavi/dns/refs/heads/main/magis.txt"
LISTAS_ORIGINALES=("mintic.txt" "coljuegos.txt" "magis.txt")
LISTAS=()

# ========================
# FUNCIONES
# ========================

declare -A DOMINIOS_PROCESADOS
TOTAL_DOMINIOS=0
VALIDOS=0
INVALIDOS=0
OMITIDOS_LISTA=()

function crear_template_db() {
  mkdir -p "$ZONES_DIR"
  cat <<EOF > "$TEMPLATE_FILE"
$TTL 86400
@   IN  SOA ns.ticcol.com. admin.ticcol.com. (
        SERIAL
        3600
        1800
        1209600
        86400 )
    IN  NS  ns.ticcol.com.
    IN  A   $IPV4_REDIRECT
    IN  AAAA $IPV6_REDIRECT
    IN  CNAME $DOMINIO_REDIRECCION
www IN  CNAME $DOMINIO_REDIRECCION
EOF
}

function limpiar_dominio() {
  local url="$1"
  echo "$url" | sed -E 's~^https?://~~' | cut -d'/' -f1 | cut -d'?' -f1 | cut -d':' -f1 | tr -d '\r' | tr '[:upper:]' '[:lower:]'
}

function es_valido_dominio() {
  local dominio="$1"
  if [[ "$dominio" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    return 1
  fi
  if [[ "$dominio" =~ : ]]; then
    return 1
  fi
  [[ "$dominio" =~ ^([a-z0-9\p{L}-]+\.)+[a-z\p{L}]{2,}$ || "$dominio" =~ ^xn-- ]] && return 0 || return 1
}

function generar_serial() {
  date +%Y%m%d%H
}

function corregir_serial() {
  local archivo="$1"
  local serial=$(grep -oE '[0-9]{8,10}' "$archivo" | head -1)
  if [[ ${#serial} -ne 10 && ${#serial} -ne 8 ]]; then
    echo "[ALERTA] Serial inválido en $archivo"
    return 1
  fi
  return 0
}

function agregar_zona_directa() {
  local dominio="$1"
  local archivo_db="$ZONES_DIR/db.$dominio"

  cp "$TEMPLATE_FILE" "$archivo_db"
  local serial=$(generar_serial)
  sed -i "s#SERIAL#$serial#" "$archivo_db"
}

function agregar_zona_include() {
  local dominio="$1"
  local origen="$2"
  local archivo_conf="$BIND_DIR/$origen.conf"
  local archivo_db="\"$ZONES_DIR/db.$dominio\""

  echo "zone \"$dominio\" { type master; file $archivo_db; };" >> "$archivo_conf"
}

function procesar_dominio() {
  local dominio="$1"
  local origen="$2"
  ((TOTAL_DOMINIOS++))

  if [[ -n "${DOMINIOS_PROCESADOS[$dominio]}" ]]; then
    return
  fi

  if es_valido_dominio "$dominio"; then
    DOMINIOS_PROCESADOS[$dominio]=1
    agregar_zona_directa "$dominio"
    agregar_zona_include "$dominio" "$origen"
    ((VALIDOS++))
  else
    OMITIDOS_LISTA+=("$dominio|Formato inválido")
    ((INVALIDOS++))
  fi
}

function descargar_lista_magis() {
  curl -s "$MAGIS_URL" -o magis.txt
}

function generar_zona_inversa_ipv4() {
  cat <<EOF > "$REV_IPV4_FILE"
$TTL 86400
@   IN  SOA ns.ticcol.com. admin.ticcol.com. (
        $(generar_serial)
        3600
        1800
        1209600
        86400 )
    IN  NS  ns.ticcol.com.
250 IN  PTR $DOMINIO_REDIRECCION
EOF
}

function generar_zona_inversa_ipv6() {
  cat <<EOF > "$REV_IPV6_FILE"
$TTL 86400
@   IN  SOA ns.ticcol.com. admin.ticcol.com. (
        $(generar_serial)
        3600
        1800
        1209600
        86400 )
    IN  NS  ns.ticcol.com.
0.5.2.0.0.0.0.2.0.0.5.8.b.3.0.8.2 IN PTR $DOMINIO_REDIRECCION
EOF
}

function mostrar_progreso() {
  local current=$1
  local total=$2
  local porcentaje=$(( current * 100 / total ))
  echo -ne "Procesando: $porcentaje% [$current/$total]\r"
}

# ========================
# PARÁMETROS OPCIONALES
# ========================

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -l|--lista)
      if [[ "$2" =~ ^(mintic|coljuegos|magis)$ ]]; then
        LISTAS+=("$2.txt")
        shift 2
      else
        echo "[ERROR] Lista no válida: $2. Opciones válidas: mintic, coljuegos, magis."
        exit 1
      fi
      ;;
    *)
      echo "[ERROR] Argumento desconocido: $1"
      exit 1
      ;;
  esac

done

if [ ${#LISTAS[@]} -eq 0 ]; then
  LISTAS=("${LISTAS_ORIGINALES[@]}")
fi

# ========================
# EJECUCION PRINCIPAL
# ========================

echo "[INFO] Inicializando..."
crear_template_db
rm -f "$OMITIDOS" "$BIND_DIR/magis.conf" "$BIND_DIR/coljuegos.conf" "$BIND_DIR/mintic.conf"

descargar_lista_magis

for lista in "${LISTAS[@]}"; do
  origen=$(basename "$lista" .txt)
  echo "[INFO] Procesando lista: $lista"
  total_lineas=$(wc -l < "$lista")
  linea_actual=0

  while read -r url; do
    ((linea_actual++))
    mostrar_progreso "$linea_actual" "$total_lineas"
    dominio=$(limpiar_dominio "$url")
    procesar_dominio "$dominio" "$origen"
  done < "$lista"
  echo ""
done

echo "[INFO] Generando zonas inversas..."
generar_zona_inversa_ipv4
generar_zona_inversa_ipv6

# ========================
# RESUMEN FINAL
# ========================

echo "[INFO] Proceso finalizado."
echo "----------------------------------------"
echo "Dominios totales: $TOTAL_DOMINIOS"
echo "Dominios válidos: $VALIDOS"
echo "Dominios inválidos: $INVALIDOS"
echo "Dominios omitidos: ${#OMITIDOS_LISTA[@]}"
echo "----------------------------------------"

if (( ${#OMITIDOS_LISTA[@]} > 0 )); then
  echo "[INFO] Registrando dominios omitidos en $OMITIDOS"
  for entrada in "${OMITIDOS_LISTA[@]}"; do
    echo "$entrada" >> "$OMITIDOS"
  done
fi
