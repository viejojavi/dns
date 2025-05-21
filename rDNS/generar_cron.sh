#!/bin/bash

# Función para validar el formato de la hora (HH:MM)
validar_hora() {
  local hora="$1"
  if [[ "$hora" =~ ^[0-2][0-9]:[0-5][0-9]$ ]]; then
    return 0 # Formato válido
  else
    return 1 # Formato inválido
  fi
}

# Función para validar el formato de la fecha (YYYY-MM-DD) - Opcional
validar_fecha() {
  local fecha="$1"
  if [[ "$fecha" =~ ^[0-9]{4}-[0-1][0-9]-[0-3][0-9]$ ]]; then
    return 0 # Formato válido
  else
    return 1 # Formato inválido
  fi
}

# Función para verificar los permisos de ejecución de un archivo
verificar_permisos_ejecucion() {
  local archivo="$1"
  if [ -f "$archivo" ] && [ -x "$archivo" ]; then
    return 0 # Tiene permisos de ejecución
  else
    return 1 # No tiene permisos de ejecución o no es un archivo
  fi
}

# Solicitar el tiempo de ejecución
echo "Ingrese el tiempo de ejecución para la tarea cron:"
echo "Formato: HH:MM (ejemplo: 10:30)"
read -p "Hora: " hora_ejecucion

# Validar el formato de la hora
if ! validar_hora "$hora_ejecucion"; then
  echo "Error: El formato de la hora ingresada no es válido."
  exit 1
fi

# Solicitar la fecha de ejecución (opcional)
read -p "Desea especificar una fecha de ejecución? (YYYY-MM-DD, dejar en blanco para todos los días): " fecha_ejecucion

# Validar el formato de la fecha si se ingresó
if [ ! -z "$fecha_ejecucion" ] && ! validar_fecha "$fecha_ejecucion"; then
  echo "Error: El formato de la fecha ingresada no es válido."
  exit 1
fi

# Solicitar la tarea a ejecutar
read -p "Ingrese el comando a ejecutar: " tarea_ejecutar

# Verificar permisos de ejecución si la tarea parece ser un script local
if [[ "$tarea_ejecutar" =~ ^(\./|\/) ]]; then
  if ! verificar_permisos_ejecucion "$tarea_ejecutar"; then
    echo "Advertencia: El script '$tarea_ejecutar' no tiene permisos de ejecución."
    echo "Asegúrate de darle permisos de ejecución con 'chmod +x $tarea_ejecutar'."
  fi
fi

# Construir la línea para el crontab
if [ -z "$fecha_ejecucion" ]; then
  linea_cron="${hora_ejecucion:3:2} ${hora_ejecucion:0:2} * * * $tarea_ejecutar"
else
  linea_cron="${hora_ejecucion:3:2} ${hora_ejecucion:0:2} ${fecha_ejecucion:8:2} ${fecha_ejecucion:5:2} * $tarea_ejecutar"
fi

# Agregar la tarea al crontab del usuario actual
(crontab -l ; echo "$linea_cron") | crontab -

# Mostrar mensaje de finalización
echo "Tarea cron agregada exitosamente:"
echo "Tiempo de ejecución: $hora_ejecucion"
if [ ! -z "$fecha_ejecucion" ]; then
  echo "Fecha de ejecución: $fecha_ejecucion"
fi
echo "Comando: $tarea_ejecutar"
echo ""
echo "Información sobre la ejecución de la tarea cron:"
echo "Las tareas cron se ejecutan con los permisos del usuario que las agrega al crontab."
echo "En este caso, la tarea se ejecutará con tus permisos de usuario ('$USER')."
echo "Asegúrate de que este usuario tenga los permisos necesarios para ejecutar el comando especificado."
