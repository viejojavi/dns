#!/bin/bash

url_github="https://raw.githubusercontent.com/viejojavi/dns/main/magis.txt"
archivo_urls="urls_bloqueadas_magis.txt"
archivo_configuracion="/etc/bind/named.conf.local"
directorio_zonas="/etc/bind/zones"
ip_redireccion="38.188.178.250" # Reemplaza con la IP IPv4 del servidor web de redirección
ipv6_redireccion="2803:b850:0:200::250" # Reemplaza con la IP IPv6 del servidor web de redirección
dominio_ns="ns1.ticcol.com." # Reemplaza con tu dominio NS
dominio_admin="admin.ticcol.com." # Reemplaza con tu dominio de administrador

# Descarga el archivo desde GitHub
if ! curl -s "$url_github" -o "$archivo_urls"; then
  echo "Error al descargar el archivo desde GitHub."
  exit 1
fi

# Elimina líneas en blanco y comentarios
sed -i '/^#\|^$/d' "$archivo_urls"

# Limpia el archivo named.conf.local
sed -i '/^zone .* {/d' "$archivo_configuracion"

# Crea el directorio de zonas si no existe
mkdir -p "$directorio_zonas"

# Obtiene la lista de archivos de zona actuales
archivos_zona_actuales=$(find "$directorio_zonas" -type f -name "*.db")

# Genera las nuevas zonas y sus archivos de zona
while IFS= read -r url; do
  if [ -n "$url" ]; then
    url=$(echo "$url" | tr -d '[:space:]')
    if echo "$url" | grep -Eq "^([a-z0-9]+(-[a-z0-9]+)*\.)+[a-z]{2,}$"; then
      archivo_zona="$directorio_zonas/$url.db"
      zona="zone \"$url\" { type master; file \"$archivo_zona\"; };"
      echo "$zona" >> "$archivo_configuracion"
      echo "Zona creada para: $url"

      # Genera el número de serie con el formato yyyymmddss
      serial=$(date +"%Y%m%d%S")

      # Genera el archivo de zona
      echo "\$TTL 3600" > "$archivo_zona"
      echo "@ IN SOA $dominio_ns $dominio_admin (" >> "$archivo_zona"
      echo "                    $serial       ; Serial" >> "$archivo_zona"
      echo "                    3600    ; Refresh" >> "$archivo_zona"
      echo "                    1800    ; Retry" >> "$archivo_zona"
      echo "                    604800  ; Expire" >> "$archivo_zona"
      echo "                    86400 ) ; Minimum TTL" >> "$archivo_zona"
      echo "@       IN      NS      $dominio_ns" >> "$archivo_zona"
      echo "@       IN      A       $ip_redireccion" >> "$archivo_zona"
      echo "@       IN      AAAA    $ipv6_redireccion" >> "$archivo_zona"

      # Elimina el archivo de zona de la lista de archivos actuales
      archivos_zona_actuales=$(echo "$archivos_zona_actuales" | sed "s|$archivo_zona||")
    else
      echo "URL inválida: $url"
    fi
  fi
done < "$archivo_urls"

# Elimina los archivos de zona huérfanos
for archivo_zona_eliminar in $archivos_zona_actuales; do
  if [ -n "$archivo_zona_eliminar" ]; then
    rm "$archivo_zona_eliminar"
    echo "Archivo de zona eliminado: $archivo_zona_eliminar"
  fi
done

echo "Zonas de redirección actualizadas en $archivo_configuracion"
sudo systemctl restart named.service

# Opcional: Elimina los archivos temporales
rm "$archivo_urls"

exit 0
