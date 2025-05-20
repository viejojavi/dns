#!/bin/bash

### CONFIGURACIÓN INICIAL ###
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
ZONES_DIR="/etc/bind/zones"
CONF_DIR="/etc/bind/zones-config"
LISTAS=(
  "$SCRIPT_DIR/coljuegos.txt"
  "$SCRIPT_DIR/mintic.txt"
  "$SCRIPT_DIR/magis.txt"
)
FORWARDERS="8.8.8.8; 1.1.1.1;"
IPV4_REDIRECT="38.188.178.250"
IPV6_REDIRECT="2803:b850:0:200::250"
LOG_FILE="/var/log/dns_manager.log"
TOTAL_DOMINIOS=0
DOMINIOS_VALIDOS=0
DOMINIOS_INVALIDOS=0
ZONAS_NUEVAS=0
ZONAS_EXISTENTES=0

### VERIFICAR DEPENDENCIAS ###
dependencias=(bind9 dnsutils curl)
for pkg in "${dependencias[@]}"; do
  dpkg -s "$pkg" &>/dev/null || apt-get install -y "$pkg"
done

### FUNCIONES ###
generar_serial() {
  date +"%Y%U%H%M"
}

validar_dominio() {
  local dominio="$1"
  [[ "$dominio" =~ ^([a-zA-Z0-9][-a-zA-Z0-9]*\.)+[a-zA-Z]{2,}$ ]]
}

crear_zona_directa() {
  local dominio="$1"
  local zone_file="$ZONES_DIR/db.${dominio//\//_}"
  local serial=$(generar_serial)

  local contenido=$(cat << EOF
$TTL    86400
@       IN      SOA     ns1.ticcol.com. admin.ticcol.com. (
                          $serial ; Serial
                          3600       ; Refresh
                          1800       ; Retry
                          1209600    ; Expire
                          86400 )    ; Negative Cache TTL
;
@       IN      NS      ns1.ticcol.com.
@       IN      A       $IPV4_REDIRECT
@       IN      AAAA    $IPV6_REDIRECT
www     IN      A       $IPV4_REDIRECT
www     IN      AAAA    $IPV6_REDIRECT
EOF
)

  if [[ -f "$zone_file" ]] && cmp -s <(echo "$contenido") "$zone_file"; then
    ((ZONAS_EXISTENTES++))
    echo "$(date) - Zona $dominio ya existe y no ha cambiado. Se omite." >> "$LOG_FILE"
  else
    echo "$contenido" > "$zone_file"
    ((ZONAS_NUEVAS++))
    echo "Zona directa creada/actualizada: $dominio"
  fi
}

crear_config_zona() {
  local dominio="$1"
  local conf_file="$CONF_DIR/${dominio//\//_}.conf"

  local contenido=$(cat << EOF
zone "$dominio" {
  type master;
  file "$ZONES_DIR/db.${dominio//\//_}";
  allow-query { any; };
};
EOF
)

  if [[ -f "$conf_file" ]] && cmp -s <(echo "$contenido") "$conf_file"; then
    echo "$(date) - Config $dominio sin cambios. Se omite." >> "$LOG_FILE"
  else
    echo "$contenido" > "$conf_file"
    echo "Configuración de zona agregada/actualizada: $dominio"
  fi
}

crear_zona_inversa() {
  local ip="$1"
  local es_ipv6="$2"
  local zona
  local archivo
  local serial=$(generar_serial)

  if [[ "$es_ipv6" == "true" ]]; then
    zona=$(echo "$ip" | awk -F: '{for(i=1;i<=NF;i++) printf "%04x", strtonum("0x"$i)}' | grep -o . | tac | paste -sd . - | sed 's/\.$//').ip6.arpa
    archivo="$ZONES_DIR/db.${zona//./_}"
  else
    zona=$(echo "$ip" | awk -F. '{print $3"."$2"."$1".in-addr.arpa"}')
    archivo="$ZONES_DIR/db.${zona//./_}"
  fi

  [[ -f "$archivo" ]] && return

  local ptr
  if [[ "$es_ipv6" == "true" ]]; then
    ptr=$(echo "$ip" | awk -F: '{for(i=1;i<=NF;i++) printf "%04x", strtonum("0x"$i)}' | grep -o . | tac | head -n 64 | paste -sd .)
    ptr_line="$ptr IN PTR bloqueados.ticcol.com."
  else
    ptr=$(echo "$ip" | awk -F. '{print $4}')
    ptr_line="$ptr IN PTR bloqueados.ticcol.com."
  fi

  cat > "$archivo" << EOF
$TTL    86400
@       IN      SOA     ns1.ticcol.com. admin.ticcol.com. (
                          $serial ; Serial
                          3600       ; Refresh
                          1800       ; Retry
                          1209600    ; Expire
                          86400 )    ; Negative Cache TTL
;
@       IN      NS      ns1.ticcol.com.
$ptr_line
EOF

  local conf_file="$CONF_DIR/${zona//./_}.conf"
  cat > "$conf_file" << EOF
zone "$zona" {
  type master;
  file "$archivo";
  allow-query { any; };
};
EOF

  echo "Zona inversa creada: $zona"
}

agregar_zonas_al_named_conf() {
  local named_local="/etc/bind/named.conf.local"
  echo -e "// Zonas administradas automáticamente\n" > "$named_local"
  for f in "$CONF_DIR"/*.conf; do
    echo "include \"$f\";" >> "$named_local"
  done

  cat > /etc/bind/named.conf.options << EOF
options {
  directory "/var/cache/bind";

  forwarders {
    $FORWARDERS
  };

  allow-recursion { any; };
  recursion yes;
  dnssec-validation auto;
  auth-nxdomain no;
  listen-on { any; };
  listen-on-v6 { any; };
};
EOF

  echo "Configuración general aplicada."
}

procesar_lista() {
  local lista="$1"
  [[ -f "$lista" ]] || return

  mapfile -t dominios < <(grep -v '^[[:space:]]*$' "$lista" | sed 's|https\?://||' | cut -d'/' -f1 | tr -d '\r' | sort -u)
  local total=${#dominios[@]}
  ((TOTAL_DOMINIOS+=total))
  local count=0

  for dominio in "${dominios[@]}"; do
    ((count++))
    local percent=$((count * 100 / total))
    echo -ne "\rProcesando $dominio ($count/$total) [$percent%]"
    if validar_dominio "$dominio"; then
      ((DOMINIOS_VALIDOS++))
      crear_zona_directa "$dominio"
      crear_config_zona "$dominio"
    else
      ((DOMINIOS_INVALIDOS++))
      echo "$(date) - Dominio inválido: $dominio" >> "$LOG_FILE"
    fi
  done
  echo -e "\nLista procesada: $lista"
}

validar_bind() {
  named-checkconf || return 1
  for z in "$ZONES_DIR"/db.*; do
    local base="$(basename "$z")"
    local d="${base#db.}"
    named-checkzone "$d" "$z" || return 1
  done
  return 0
}

reiniciar_bind() {
  if validar_bind; then
    systemctl reload bind9 && echo "Bind recargado con éxito." >> "$LOG_FILE"
    echo "Bind recargado exitosamente."
  else
    echo "Error en configuración BIND. Verifica named-checkconf y named-checkzone." | tee -a "$LOG_FILE"
  fi
}

### EJECUCIÓN PRINCIPAL ###
mkdir -p "$ZONES_DIR" "$CONF_DIR"
echo "$(date) - Inicio de ejecución" >> "$LOG_FILE"

for lista in "${LISTAS[@]}"; do
  if [[ -f "$lista" ]]; then
    procesar_lista "$lista"
  else
    echo "$(date) - Advertencia: Lista no encontrada: $lista" >> "$LOG_FILE"
  fi
  echo "Finalizó procesamiento de lista: $lista"
done

crear_zona_inversa "$IPV4_REDIRECT" false
crear_zona_inversa "$IPV6_REDIRECT" true

agregar_zonas_al_named_conf
reiniciar_bind

echo "$(date) - Fin de ejecución" >> "$LOG_FILE"
echo -e "\nResumen Final:"
echo "  Total dominios procesados: $TOTAL_DOMINIOS"
echo "  Dominios válidos configurados: $DOMINIOS_VALIDOS"
echo "  Dominios inválidos u omitidos: $DOMINIOS_INVALIDOS"
echo "  Zonas nuevas creadas: $ZONAS_NUEVAS"
echo "  Zonas ya existentes sin cambios: $ZONAS_EXISTENTES"
echo -e "\nProceso completado. Verifica $LOG_FILE para más detalles."
