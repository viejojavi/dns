#!/bin/bash

# Configuración
ZONAS_DIR="/etc/bind/zones"
LOG_DIR="/var/log/dns_manager"
LOGO_DIR="/var/www/html/logos"
OMITIDOS_LOG="$LOG_DIR/omitidos.log"
REVERSE_CONF_V4="$ZONAS_DIR/db.38.188.178.250"
REVERSE_CONF_V6="$ZONAS_DIR/db.2803.b850.0.200"
IPV4_REDIR="38.188.178.250"
IPV6_REDIR="2803:b850:0:200::250"
DNS_TARGET="redireccion.blocked.local."
MAGIS_URL="https://raw.githubusercontent.com/viejojavi/dns/refs/heads/main/magis.txt"
MAGIS_LOCAL="magis.txt"

# Estadísticas
DOMINIOS_TOTAL=0
DOMINIOS_VALIDOS=0
DOMINIOS_INVALIDOS=0
ZONAS_CREADAS=0
ZONAS_ACTUALIZADAS=0
ZONAS_ELIMINADAS=0

# Colores
VERDE="\e[32m"
ROJO="\e[31m"
AZUL="\e[34m"
AMARILLO="\e[33m"
RESET="\e[0m"

verificar_dependencias() {
  echo "[+] Verificando dependencias..."
  for pkg in idn2 python3 curl; do
    if ! command -v $pkg &>/dev/null; then
      echo "[-] Instalando $pkg..."
      apt-get update -qq && apt-get install -y -qq $pkg
    fi
  done
}

validar_dominio() {
  dominio="$1"
  dominio_ascii=$(idn2 "$dominio" 2>/dev/null)
  [[ -z "$dominio_ascii" ]] && return 1
  [[ "$dominio_ascii" =~ ^([a-zA-Z0-9-]{1,63}\.)+[a-zA-Z]{2,}$ ]] && return 0 || return 1
}

crear_zona_directa() {
  dominio="$1"
  archivo="$ZONAS_DIR/db.$dominio"

  if [[ -f "$archivo" ]]; then
    ZONAS_ACTUALIZADAS=$((ZONAS_ACTUALIZADAS + 1))
  else
    ZONAS_CREADAS=$((ZONAS_CREADAS + 1))
  fi

  cat >"$archivo" <<EOF
\$TTL 86400
@   IN  SOA ns1.$dominio. admin.$dominio. (
        $(date +%Y%m%d%H)
        3600
        1800
        604800
        86400 )
;
@       IN  NS      ns1.$dominio.
@       IN  A       $IPV4_REDIR
@       IN  AAAA    $IPV6_REDIR
www     IN  CNAME   @
EOF
}

crear_zona_inversa_ipv4() {
  cat >"$REVERSE_CONF_V4" <<EOF
\$TTL 86400
@   IN  SOA ns1.blocked.local. admin.blocked.local. (
        $(date +%Y%m%d%H)
        3600
        1800
        604800
        86400 )
;
@   IN  NS ns1.blocked.local.
250 IN PTR $DNS_TARGET.
EOF
}

crear_zona_inversa_ipv6() {
  cat >"$REVERSE_CONF_V6" <<EOF
\$TTL 86400
@   IN  SOA ns1.blocked.local. admin.blocked.local. (
        $(date +%Y%m%d%H)
        3600
        1800
        604800
        86400 )
;
@   IN  NS ns1.blocked.local.

\$ORIGIN 0.0.0.0.0.0.0.0.0.2.0.0.0.0.5.8.b.3.0.8.2.ip6.arpa.
0.5.2 IN PTR $DNS_TARGET.
EOF
}

procesar_lista() {
  lista="$1"
  echo "[+] Procesando lista: $lista"

  total=$(grep -cve '^\s*$' "$lista")
  count=0

  while IFS= read -r linea || [[ -n "$linea" ]]; do
    ((count++))
    porcentaje=$((count * 100 / total))

    if [[ "$lista" == "mintic.txt" ]]; then
      dominio=$(echo "$linea" | sed -E 's|https?://||;s|/.*||;s|^www\.||')
    else
      dominio=$(echo "$linea" | grep -oP '(https?://)?\K[^/]+')
    fi

    dominio=${dominio,,} # a minúsculas
    ((DOMINIOS_TOTAL++))

    if validar_dominio "$dominio"; then
      crear_zona_directa "$dominio"
      ((DOMINIOS_VALIDOS++))
    else
      echo "$dominio" >> "$OMITIDOS_LOG"
      ((DOMINIOS_INVALIDOS++))
    fi

    printf "\r[+] Progreso: %3d%%" "$porcentaje"
  done <"$lista"
  echo
}

descargar_magis() {
  echo "[+] Descargando magis.txt desde GitHub..."
  curl -s -o "$MAGIS_LOCAL" "$MAGIS_URL"
  if [[ ! -s "$MAGIS_LOCAL" ]]; then
    echo "[-] Error al descargar magis.txt"
    exit 1
  fi
}

preparar_estructura() {
  mkdir -p "$ZONAS_DIR" "$LOG_DIR" "$LOGO_DIR"
  > "$OMITIDOS_LOG"  # Limpiar log de omitidos
}

resumen_final() {
  echo -e "\n${AZUL}========= RESUMEN DE OPERACIÓN =========${RESET}"
  echo -e "${AMARILLO}Dominios totales:     ${DOMINIOS_TOTAL}${RESET}"
  echo -e "${VERDE}Dominios válidos:     ${DOMINIOS_VALIDOS}${RESET}"
  echo -e "${ROJO}Dominios omitidos:    ${DOMINIOS_INVALIDOS}${RESET}"
  echo -e "${VERDE}Zonas creadas:        ${ZONAS_CREADAS}${RESET}"
  echo -e "${AZUL}Zonas actualizadas:   ${ZONAS_ACTUALIZADAS}${RESET}"
  echo -e "${ROJO}Zonas eliminadas:     ${ZONAS_ELIMINADAS}${RESET}"  # No eliminamos en esta versión
  echo -e "${AZUL}=========================================${RESET}"
  echo -e "${AMARILLO}Omitidos guardados en:${RESET} $OMITIDOS_LOG"
}

main() {
  verificar_dependencias
  preparar_estructura

  crear_zona_inversa_ipv4
  crear_zona_inversa_ipv6

  [[ -f "coljuegos.txt" ]] && procesar_lista "coljuegos.txt"
  [[ -f "mintic.txt" ]] && procesar_lista "mintic.txt"

  descargar_magis
  procesar_lista "$MAGIS_LOCAL"

  resumen_final
}

main "$@"
