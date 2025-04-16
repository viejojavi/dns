#!/bin/bash

# Asistente de configuración de BIND para Ubuntu Server con soporte rDNS

set -e

# 1. Solicitar datos
read -rp "Ingrese el dominio de la empresa (ej. ejemplo.com): " dominio
read -rp "Ingrese el nombre del servidor DNS (ej. ns2): " nombre_dns
read -rp "Ingrese el correo del administrador (ej. admin@ejemplo.com): " email
read -rp "Ingrese la IP IPv4 asignada: " ipv4
read -rp "Ingrese el rango IPv6 asignado por LACNIC: " ipv6_rango

# Validar pertenencia de IP al rango autorizado
function ip_en_rango_ipv6() {
  ipcalc -6 "$1/$2" | grep -q "$1"
}

function ip_en_rango_ipv4() {
  [[ "$1" == "$ipv4" ]]
}

# Solicitar subdominios e IPs para registros PTR
declare -A ptr_registros
while true; do
  read -rp "Ingrese un subdominio para PTR (o ENTER para terminar): " subdom
  [[ -z "$subdom" ]] && break
  read -rp "Ingrese la IP (IPv4 o IPv6) correspondiente para $subdom: " ptr_ip

  if [[ "$ptr_ip" == *:* ]]; then
    if ! [[ "$ptr_ip" =~ ^$ipv6_rango ]]; then
      echo "La IP $ptr_ip no pertenece al rango IPv6 autorizado $ipv6_rango. Intente de nuevo."
      continue
    fi
  else
    if ! ip_en_rango_ipv4 "$ptr_ip"; then
      echo "La IP $ptr_ip no coincide con la IPv4 autorizada $ipv4. Intente de nuevo."
      continue
    fi
  fi
  ptr_registros["$subdom"]="$ptr_ip"
done

serial=$(date +%Y%m%d%H)
dns_fqdn="$nombre_dns.$dominio"
archivo_zona_directa="/etc/bind/zones/$dns_fqdn"
archivo_zona_reversa="/etc/bind/zones/rango_ip.reverse"

# 2. Instalar BIND
apt update && apt install -y bind9 bind9utils bind9-doc apparmor-utils

# 3. Configurar named.conf.options
cat <<EOF > /etc/bind/named.conf.options
options {
	directory "/var/cache/bind";
	dnssec-validation auto;
	listen-on port 53 { any; };
	listen-on-v6 { any; };
	recursion no;
};
EOF

# 4. named.conf.local con include reverse
grep -q 'named.conf.reverse' /etc/bind/named.conf.local || echo 'include "/etc/bind/named.conf.reverse";' >> /etc/bind/named.conf.local

# 5. Crear named.conf.reverse
mkdir -p /etc/bind/zones /etc/bind/keys
zona_ipv6=$(echo "$ipv6_rango" | sed 's/::.*//' | sed 's/:/ /g' | awk '{for(i=NF;i>0;i--) for(j=length($i);j>0;j--) printf "%s.", substr($i,j,1)}')
zona_ipv6="${zona_ipv6}ip6.arpa"
cat <<EOF > /etc/bind/named.conf.reverse
zone "$dns_fqdn" {
	type master;
	file "/etc/bind/zones/$dns_fqdn";
	key-directory "/etc/bind/keys";
	auto-dnssec maintain;
	inline-signing yes;
};

zone "$zona_ipv6" {
	type master;
	file "/etc/bind/zones/rango_ip.reverse";
	key-directory "/etc/bind/keys";
	auto-dnssec maintain;
	inline-signing yes;
};
EOF

# 6. Crear archivo de zona directa
cat <<EOF > "$archivo_zona_directa"
\$TTL 300
@ IN SOA $dns_fqdn. ${email//@/.}. (
	$serial ;serial
	3600 ;refresh
	600 ;retry
	2419200 ;expire
	300 ;minimum
)
@ NS $dns_fqdn.
EOF

for sub in "${!ptr_registros[@]}"; do
  ip="${ptr_registros[$sub]}"
  if [[ $ip =~ ":" ]]; then
    tipo="AAAA"
  else
    tipo="A"
  fi
  echo "$sub $tipo $ip" >> "$archivo_zona_directa"
done

# 7. Crear archivo de zona reversa
cat <<EOF > "$archivo_zona_reversa"
\$TTL 300
@ IN SOA $dns_fqdn. ${email//@/.}. (
	$serial ;serial
	3600 ;refresh
	600 ;retry
	2419200 ;expire
	300 ;minimum
)
@ NS $dns_fqdn.
EOF

for sub in "${!ptr_registros[@]}"; do
  ip="${ptr_registros[$sub]}"
  if [[ $ip =~ ":" ]]; then
    full_nibbles=$(echo "$ip" | sed 's/://g' | awk '{for(i=length;i>0;i--) printf "%s.", substr($0,i,1)}')
    echo "$full_nibbles IN PTR $sub.$dominio." >> "$archivo_zona_reversa"
  else
    octets=$(echo "$ip" | awk -F. '{print $4"."$3"."$2"."$1}')
    echo "$octets.in-addr.arpa. IN PTR $sub.$dominio." >> "$archivo_zona_reversa"
  fi
  done

# 8. Asignar permisos al usuario bind
chown -R bind:bind /etc/bind/zones
chmod -R 770 /etc/bind/zones

# 9. Verificar y ajustar AppArmor si es necesario
if aa-status | grep -q "/usr/sbin/named"; then
  echo "AppArmor está habilitado para named. Cambiando a modo complain..."
  aa-complain /usr/sbin/named
fi

# 10. Reiniciar BIND
systemctl restart bind9

# 11. Verificar estado
systemctl status bind9

# 12. Validar que los archivos fueron creados correctamente
echo "\nVerificando archivos de zona..."
if [[ -s "$archivo_zona_directa" && -s "$archivo_zona_reversa" ]]; then
  echo "Archivos de zona generados correctamente."
else
  echo "Error: Uno o ambos archivos de zona están vacíos o no existen."
fi

# 13. Probar resolución inversa
read -rp "Ingrese una IP del rango autorizado para verificar con dig: " test_ip
dig -x "$test_ip"
