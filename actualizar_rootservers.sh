#!/bin/bash

# Ruta al archivo que vamos a reemplazar
db_root_path="/etc/bind/db.root"
# Ruta donde se almacenará la copia de seguridad
backup_path="/etc/bind/db.root.bak"
# URL del archivo que vamos a descargar
url="https://www.internic.net/domain/named.root"

# Paso 1: Crear copia de seguridad del archivo db.root
echo "Creando copia de seguridad de $db_root_path a $backup_path..."
cp $db_root_path $backup_path

# Verificar si la copia de seguridad se creó correctamente
if [ $? -eq 0 ]; then
    echo "Copia de seguridad creada exitosamente en $backup_path"
else
    echo "Error al crear la copia de seguridad. Abortando."
    exit 1
fi

# Paso 2: Descargar el archivo actualizado desde Internic
echo "Descargando el archivo desde $url..."
curl -o $db_root_path $url

# Verificar si la descarga fue exitosa
if [ $? -eq 0 ]; then
    echo "Archivo descargado y reemplazado exitosamente."
else
    echo "Error al descargar el archivo. Restaurando la copia de seguridad."
    cp $backup_path $db_root_path
    exit 1
fi

# Paso 3: Verificar si todo está bien
echo "Proceso completado."
