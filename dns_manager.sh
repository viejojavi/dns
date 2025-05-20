#!/bin/bash

# Configuración
ZONAS_DIR="/etc/bind/zones"
LOG_DIR="/var/log/dns_manager"
LOGO_DIR="/var/www/html/logos"
REVERSE_CONF_V4="$ZONAS_DIR/db.38.188.178.250"
REVERSE_CONF_V6="$ZONAS_DIR/db.2803.b850.0.200"
IPV4_REDIR="38.188.178.250"
IPV6_REDIR="2803:b850:0:200::250"
DNS_TARGET="redireccion.blocked.local."

# Requisitos
verificar_dependencias() {
  echo "[+] Verificando dependencias..."
  for pkg in idn2 python3; do
    if ! command -v $pkg &> /dev/null; then
      echo "[-] Instalando $pkg..."
      apt-get update -qq && apt-get install -y -qq $pkg
    fi
  done
}

# Validación de dominio incluyendo punycode y TLDs nuevos
validar_dominio() {
  dominio="$1"
  dominio_ascii=$(idn2 "$dominio" 2>/dev/null)
  [[ -z "$dominio_ascii" ]] && return 1
  [[ "$dominio_ascii" =~ ^([a-zA-Z0-9-]{1,63}\.)+[a-zA-Z]{2,}$ ]] && return 0 || return 1
}

# Crear zona directa para un dominio
crear_zona_directa() {
  dominio="$1"
  archivo="$ZONAS_DIR/db.$dominio"
  cat > "$archivo" <<EOF
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

# Crear zona inversa para IPv4
crear_zona_inversa_ipv4() {
  cat > "$REVERSE_CONF_V4" <<EOF
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

# Crear zona inversa para IPv6 (simplificada con $ORIGIN)
crear_zona_inversa_ipv6() {
  cat > "$REVERSE_CONF_V6" <<EOF
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

# Procesar lista de dominios
procesar_lista() {
  lista="$1"
  echo "[+] Procesando lista: $lista"
  while IFS= read -r linea || [[ -n "$linea" ]]; do
    # Extraer dominio según tipo de archivo
    if [[ "$lista" == "mintic.txt" ]]; then
      dominio=$(echo "$linea" | sed -E 's|https?://||;s|/.*||;s|^www\.||')
    else
      dominio=$(echo "$linea" | grep -oP '(https?://)?\K[^/]+')
    fi

    validar_dominio "$dominio"
    if [[ $? -eq 0 ]]; then
      echo "✓ Dominio válido: $dominio"
      crear_zona_directa "$dominio"
    else
      echo "✗ Dominio inválido: $linea"
    fi
  done < "$lista"
}

# Crear estructura inicial
preparar_estructura() {
  mkdir -p "$ZONAS_DIR" "$LOG_DIR" "$LOGO_DIR"
}

# Main
main() {
  verificar_dependencias
  preparar_estructura

  crear_zona_inversa_ipv4
  crear_zona_inversa_ipv6

  for archivo in coljuegos.txt mintic.txt magis.txt; do
    [[ -f "$archivo" ]] && procesar_lista "$archivo"
  done

  echo "[✔] Proceso finalizado."
}

main "$@"
