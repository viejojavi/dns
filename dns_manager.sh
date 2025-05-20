#!/bin/bash

### CONFIGURACIÓN GLOBAL ###
IPV4_REDIRECT="38.188.178.250"
IPV6_REDIRECT="2803:b850:0:200::250"
PTR_DOMAIN="bloqueo.cirtedns.local."
ZONES_DIR="/etc/bind/zones"
LOG_DIR="/var/log/dns_manager"
LOGO_DIR="/var/www/logos"
NAMED_LOCAL="/etc/bind/named.conf.local"

### ARCHIVOS DE LISTAS ###
COLJUEGOS="coljuegos.txt"
MINTIC="mintic.txt"
MAGIS_URL="https://raw.githubusercontent.com/viejojavi/dns/refs/heads/main/magis.txt"
MAGIS="magis.txt"

### FUNCIONES ###

function check_dependencies() {
  echo "🔍 Verificando dependencias..."
  for pkg in bind9 idn2 python3; do
    if ! dpkg -s "$pkg" &>/dev/null; then
      echo "🛠 Instalando $pkg..."
      apt-get install -y "$pkg"
    fi
  done
  mkdir -p "$ZONES_DIR" "$LOG_DIR" "$LOGO_DIR"
}

function download_lists() {
  echo "⬇️  Descargando listas..."
  curl -s "$MAGIS_URL" -o "$MAGIS"
}

function extract_domain() {
  local url="$1"
  echo "$url" | sed -E 's#https?://([^/]+).*#\1#' | sed 's/^www\.//' | tr '[:upper:]' '[:lower:]'
}

function is_valid_domain() {
  local domain="$1"
  echo "$domain" | grep -Pq "^(?!-)[a-z0-9]+([-.]{1,2}[a-z0-9]+)*\.[a-z]{2,}$"
}

function generate_zone_file() {
  local domain="$1"
  local zone_file="$2"
  cat > "$zone_file" <<EOF
\$TTL 1H
@   IN  SOA ns1.cirtedns.local. admin.cirtedns.local. (
          $(date +%Y%m%d%H) ; Serial
          1H ; Refresh
          15M ; Retry
          1W ; Expire
          1D ) ; Minimum TTL

    IN  NS  ns1.cirtedns.local.
    IN  A   $IPV4_REDIRECT
    IN  AAAA $IPV6_REDIRECT
www IN  A   $IPV4_REDIRECT
www IN  AAAA $IPV6_REDIRECT
EOF
}

function create_zone_entry() {
  local domain="$1"
  local zone_file="$2"
  echo "zone \"$domain\" {
  type master;
  file \"$zone_file\";
};" > "$ZONES_DIR/conf_$domain.zone"
}

function generate_ptr_zones() {
  local ptr_file_v4="$ZONES_DIR/ptr_v4.zone"
  local ptr_file_v6="$ZONES_DIR/ptr_v6.zone"
  local ip4_zone="250.178.188.38.in-addr.arpa"
  local ip6_zone="0.5.2.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.3.8.0.2.ip6.arpa"

  cat > "$ptr_file_v4" <<EOF
\$TTL 1H
@   IN  SOA ns1.cirtedns.local. admin.cirtedns.local. (
          $(date +%Y%m%d%H) ; Serial
          1H ; Refresh
          15M ; Retry
          1W ; Expire
          1D ) ; Minimum TTL

    IN  NS  ns1.cirtedns.local.
250 IN  PTR $PTR_DOMAIN
EOF

  cat > "$ptr_file_v6" <<EOF
\$TTL 1H
@   IN  SOA ns1.cirtedns.local. admin.cirtedns.local. (
          $(date +%Y%m%d%H) ; Serial
          1H ; Refresh
          15M ; Retry
          1W ; Expire
          1D ) ; Minimum TTL

    IN  NS  ns1.cirtedns.local.
250.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.3.8.0.2 IN PTR $PTR_DOMAIN
EOF

  echo "zone \"$ip4_zone\" {
  type master;
  file \"$ptr_file_v4\";
};" > "$ZONES_DIR/conf_ptr_v4.zone"

  echo "zone \"$ip6_zone\" {
  type master;
  file \"$ptr_file_v6\";
};" > "$ZONES_DIR/conf_ptr_v6.zone"
}

function process_list() {
  local list="$1"
  local list_name="$2"
  local temp_zone="$ZONES_DIR/zones_$list_name"
  mkdir -p "$temp_zone"
  local total=0 valid=0 invalid=0
  local omit_file="$LOG_DIR/omitidos_$list_name.txt"
  echo "" > "$omit_file"

  mapfile -t lines < "$list"
  total=${#lines[@]}
  echo "🔁 Procesando $total dominios de $list_name..."
  for i in "${!lines[@]}"; do
    line="${lines[$i]}"
    domain=$(extract_domain "$line")
    idn_domain=$(idn2 "$domain" 2>/dev/null)
    if is_valid_domain "$idn_domain"; then
      zone_file="$temp_zone/db.$idn_domain"
      generate_zone_file "$idn_domain" "$zone_file"
      create_zone_entry "$idn_domain" "$zone_file"
      ((valid++))
    else
      echo "$domain" >> "$omit_file"
      ((invalid++))
    fi
    percent=$(( (i+1) * 100 / total ))
    echo -ne "\r🚧 Progreso: $percent%"
  done
  echo -e "\n✅ $valid dominios válidos, ❌ $invalid omitidos."
}

function update_named_conf() {
  echo "// Archivo original preservado" > "$NAMED_LOCAL"
  for f in "$ZONES_DIR"/conf_*.zone; do
    echo "include \"$f\";" >> "$NAMED_LOCAL"
  done
}

function summary_report() {
  echo -e "\n📊 RESUMEN FINAL"
  for file in "$LOG_DIR"/omitidos_*.txt; do
    list_name=$(basename "$file" | cut -d_ -f2 | cut -d. -f1)
    total=$(wc -l < "$1")
    valid=$(find "$ZONES_DIR/zones_$list_name" -type f | wc -l)
    omitidos=$(wc -l < "$file")
    echo -e "🗂 Lista: $list_name | ✅ Válidos: $valid | ❌ Omitidos: $omitidos"
  done
}

### EJECUCIÓN ###
check_dependencies
download_lists
process_list "$COLJUEGOS" "coljuegos"
process_list "$MINTIC" "mintic"
process_list "$MAGIS" "magis"
generate_ptr_zones
update_named_conf
summary_report

systemctl reload bind9

exit 0
