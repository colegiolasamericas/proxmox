#!/usr/bin/env bash

# Copyright (c) 2025 Kernel
# Autor: Kernel
# Licencia: MIT

# Configuración de colores para la salida en consola
YW=$(echo "\033[33m")
YWB=$(echo "\033[93m")
BL=$(echo "\033[36m")
RD=$(echo "\033[01;31m")
GN=$(echo "\033[1;92m")

CL=$(echo "\033[m")
BFR="\\r\\033[K"
TAB="  "

CM="${TAB}✔️${TAB}${CL}"
CROSS="${TAB}✖️${TAB}${CL}"
INFO="${TAB}💡${TAB}${CL}"

set -Eeuo pipefail
trap 'manejador_error $LINENO "$BASH_COMMAND"' ERR

function manejador_error() {
  if [ -n "$SPINNER_PID" ] && ps -p $SPINNER_PID >/dev/null; then kill $SPINNER_PID >/dev/null; fi
  printf "\e[?25h"
  local codigo="$?"
  local linea="$1"
  local comando="$2"
  echo -e "\n${RD}[ERROR]${CL} en línea ${RD}$linea${CL}: código de salida ${RD}$codigo${CL}: ejecutando comando ${YW}$comando${CL}\n"
  exit 200
}

function spinner() {
  local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  local i=0
  local intervalo=0.1
  printf "\e[?25l"
  local color="${YWB}"
  while true; do
    printf "\r ${color}%s${CL}" "${frames[i]}"
    i=$(((i + 1) % ${#frames[@]}))
    sleep "$intervalo"
  done
}

function msg_info() {
  local msg="$1"
  echo -ne "${TAB}${YW}${msg}${CL}"
  spinner &
  SPINNER_PID=$!
}

function msg_ok() {
  if [ -n "$SPINNER_PID" ] && ps -p $SPINNER_PID >/dev/null; then kill $SPINNER_PID >/dev/null; fi
  printf "\e[?25h"
  local msg="$1"
  echo -e "${BFR}${CM}${GN}${msg}${CL}"
}

function msg_warn() {
  if [ -n "$SPINNER_PID" ] && ps -p $SPINNER_PID >/dev/null; then kill $SPINNER_PID >/dev/null; fi
  printf "\e[?25h"
  local msg="$1"
  echo -e "${BFR}${INFO}${YWB}${msg}${CL}"
}

function msg_error() {
  if [ -n "$SPINNER_PID" ] && ps -p $SPINNER_PID >/dev/null; then kill $SPINNER_PID >/dev/null; fi
  printf "\e[?25h"
  local msg="$1"
  echo -e "${BFR}${CROSS}${RD}${msg}${CL}"
}

msg_info "Validando almacenamiento disponible..."
ALMACENAMIENTO_CONTENEDOR=$(pvesm status -content rootdir | awk 'NR>1')
if [ -z "$ALMACENAMIENTO_CONTENEDOR" ]; then
  msg_error "No se detectó almacenamiento válido para contenedores."
  exit 1
fi

ALMACENAMIENTO_PLANTILLAS=$(pvesm status -content vztmpl | awk 'NR>1')
if [ -z "$ALMACENAMIENTO_PLANTILLAS" ]; then
  msg_error "No se detectó almacenamiento válido para plantillas."
  exit 1
fi
msg_ok "Almacenamiento detectado correctamente."

function seleccionar_almacenamiento() {
  local tipo=$1
  local contenido etiqueta

  if [[ $tipo == "contenedor" ]]; then
    contenido="rootdir"
    etiqueta="Contenedor"
  elif [[ $tipo == "plantilla" ]]; then
    contenido="vztmpl"
    etiqueta="Plantilla"
  else
    msg_error "Tipo de almacenamiento inválido."
    exit 2
  fi

  local -a opciones
  while read -r linea; do
    local tag=$(echo $linea | awk '{print $1}')
    local tipo_storage=$(echo $linea | awk '{printf "%-10s", $2}')
    local libre=$(echo $linea | numfmt --field 4-6 --from-unit=K --to=iec --format %.2f | awk '{printf( "%9sB", $6)}')
    local item="Tipo: $tipo_storage Libre: $libre"
    opciones+=("$tag" "$item" "OFF")
  done < <(pvesm status -content $contenido | awk 'NR>1')

  if [ $((${#opciones[@]} / 3)) -eq 1 ]; then
    printf "%s" "${opciones[0]}"
  else
    local seleccion
    seleccion=$(whiptail --backtitle "Scripts Proxmox VE" --title "Seleccione almacenamiento para $etiqueta" --radiolist \
      "Seleccione almacenamiento para $etiqueta:" 16 60 6 "${opciones[@]}" 3>&1 1>&2 2>&3) || {
      msg_error "Selección cancelada."
      exit 3
    }
    printf "%s" "$seleccion"
  fi
}

# Variables que debes definir antes de ejecutar el script:
# CTID: ID del contenedor (>= 100)
# PCT_OSTYPE: tipo de plantilla LXC, por ejemplo 'debian'
# PCT_OSVERSION: versión del sistema operativo, por ejemplo '11' para Debian 11
# PCT_DISK_SIZE: tamaño del disco (en GB), ejemplo 8

[[ "${CTID:-}" ]] || { msg_error "Debes definir la variable CTID (ID del contenedor)"; exit 4; }
[[ "${PCT_OSTYPE:-}" ]] || { msg_error "Debes definir la variable PCT_OSTYPE (tipo de plantilla, ej: debian)"; exit 5; }
[[ "${CTID}" -ge 100 ]] || { msg_error "El ID del contenedor debe ser mayor o igual a 100"; exit 6; }

if pct status "$CTID" &>/dev/null; then
  msg_error "El ID $CTID ya está en uso."
  exit 7
fi

# Seleccionamos almacenamiento para plantilla y contenedor
STORAGE_PLANTILLA=$(seleccionar_almacenamiento plantilla)
msg_ok "Se usará almacenamiento ${BL}$STORAGE_PLANTILLA${CL} para la plantilla."

STORAGE_CONTENEDOR=$(seleccionar_almacenamiento contenedor)
msg_ok "Se usará almacenamiento ${BL}$STORAGE_CONTENEDOR${CL} para el contenedor."

# Actualizamos lista de plantillas
msg_info "Actualizando lista de plantillas LXC..."
pveam update >/dev/null
msg_ok "Lista de plantillas actualizada."

# Buscamos plantilla
BUSQUEDA_PLANTILLA="${PCT_OSTYPE}-${PCT_OSVERSION:-}"
mapfile -t PLANTILLAS < <(pveam available -section system | sed -n "s/.*\($BUSQUEDA_PLANTILLA.*\)/\1/p" | sort -t - -k 2 -V)

[ ${#PLANTILLAS[@]} -gt 0 ] || { msg_error "No se encontró plantilla para $BUSQUEDA_PLANTILLA"; exit 8; }
PLANTILLA="${PLANTILLAS[-1]}"
RUTA_PLANTILLA="$(pvesm path $STORAGE_PLANTILLA:vztmpl/$PLANTILLA)"

# Validamos plantilla
if ! pveam list "$STORAGE_PLANTILLA" | grep -q "$PLANTILLA" || ! zstdcat "$RUTA_PLANTILLA" | tar -tf - >/dev/null 2>&1; then
  msg_warn "Plantilla $PLANTILLA no encontrada o corrupta. Descargando nuevamente."
  [[ -f "$RUTA_PLANTILLA" ]] && rm -f "$RUTA_PLANTILLA"

  for intento in {1..3}; do
    msg_info "Intento $intento: Descargando plantilla..."
    if timeout 120 pveam download "$STORAGE_PLANTILLA" "$PLANTILLA" >/dev/null; then
      msg_ok "Descarga exitosa."
      break
    fi
    if [ $intento -eq 3 ]; then
      msg_error "Fallaron 3 intentos de descarga. Abortando."
      exit 9
    fi
    sleep $((intento * 5))
  done
fi
msg_ok "Plantilla lista para usar."

# Verificamos /etc/subuid y /etc/subgid
grep -q "root:100000:65536" /etc/subuid || echo "root:100000:65536" >> /etc/subuid
grep -q "root:100000:65536" /etc/subgid || echo "root:100000:65536" >> /etc/subgid

# Opciones para crear el contenedor
OPCIONES_CTR=(-hostname asterisk-ct$CTID -net0 name=eth0,bridge=vmbr0,ip=dhcp,tag=10,type=veth -rootfs "$STORAGE_CONTENEDOR:${PCT_DISK_SIZE:-8}" -memory 512 -cores 1 -unprivileged 1 -features nesting=1)

msg_info "Creando contenedor LXC..."
if ! pct create "$
