#!/bin/bash
set -e

# === Variables configurables (pueden sobreescribirse antes de ejecutar) ===
export CT_ID="${CT_ID:-9001}"
export CT_HOSTNAME="${CT_HOSTNAME:-jellyfin-ct}"
export CT_PASSWORD="${CT_PASSWORD:-rootpassword}"  # Cambia esto por defecto
export CT_TEMPLATE="${CT_TEMPLATE:-ubuntu-2204-standard}"
export CT_STORAGE="${CT_STORAGE:-local-zfs}"       # Almacenamiento Proxmox
export CT_CORES="${CT_CORES:-2}"
export CT_MEMORY="${CT_MEMORY:-2048}"              # MB
export CT_SWAP="${CT_SWAP:-512}"                    # MB

# Directorios multimedia (ajusta según tu sistema)
export MEDIA_DIR="${MEDIA_DIR:-/mnt/pve/media}"
export CONFIG_DIR="${CONFIG_DIR:-$MEDIA_DIR/jellyfin-config}"
export MOVIES_DIR="${MOVIES_DIR:-$MEDIA_DIR/movies}"
export TVSHOWS_DIR="${TVSHOWS_DIR:-$MEDIA_DIR/tvshows}"

# === Crear directorios si no existen ===
echo "🔧 Creando directorios necesarios..."
mkdir -p "$CONFIG_DIR" "$MOVIES_DIR" "$TVSHOWS_DIR"
chown -R 1000:1000 "$MEDIA_DIR"
chmod -R 775 "$MEDIA_DIR"

# === Descargar plantilla si no existe ===
echo "📦 Verificando plantilla..."

# Variables (ajustadas para .tar.zst)
TEMPLATE_DIR="/var/lib/vz/template/cache"
TEMPLATE_NAME="ubuntu-22.04-standard_22.04-1_amd64"
TEMPLATE_EXT=".tar.zst"
TEMPLATE_URL="https://download.proxmox.com/apltemplate/tar.zst/${TEMPLATE_NAME}${TEMPLATE_EXT}" 

if [ ! -f "${TEMPLATE_DIR}/${TEMPLATE_NAME}${TEMPLATE_EXT}" ]; then
    echo "📥 Descargando plantilla ${TEMPLATE_NAME}..."
    mkdir -p "$TEMPLATE_DIR"
    curl -fsSL "$TEMPLATE_URL" -o "${TEMPLATE_DIR}/${TEMPLATE_NAME}${TEMPLATE_EXT}"
    
    echo "_unpacking..."
    tar --use-compress-program=unzstd -xf "${TEMPLATE_DIR}/${TEMPLATE_NAME}${TEMPLATE_EXT}" -C "$TEMPLATE_DIR"
    echo "✅ Plantilla descargada y descomprimida."
else
    echo "✅ La plantilla ya está disponible."
fi
# === Crear contenedor LXC ===
echo "🧱 Creando contenedor LXC (ID: $CT_ID)..."
if pct status $CT_ID &>/dev/null; then
    echo "⚠️ Ya existe un contenedor con ID $CT_ID. Eliminándolo..."
    pct stop $CT_ID && pct destroy $CT_ID || true
fi

pct create $CT_ID $CT_TEMPLATE \
    --hostname "$CT_HOSTNAME" \
    --cores "$CT_CORES" \
    --memory "$CT_MEMORY" \
    --swap "$CT_SWAP" \
    --storage "$CT_STORAGE" \
    --password "$CT_PASSWORD" \
    --unprivileged 1 \
    --features nesting=1 \
    --mp0 "$MEDIA_DIR,mp=/media" \
    --net0 name=eth0,ip=dhcp

# === Iniciar contenedor ===
echo "🟢 Iniciando contenedor..."
pct start $CT_ID

# === Actualizar e instalar dependencias ===
echo "⚙️ Configurando dentro del contenedor..."
pct exec $CT_ID -- bash -c "
apt update && apt upgrade -y
apt install -y curl docker.io docker-compose
"

# === Crear docker-compose.yml ===
echo "📋 Escribiendo docker-compose.yml..."
pct exec $CT_ID -- bash -c "cat > /root/docker-compose.yml <<EOF
version: '3'
services:
  jellyfin:
    image: jellyfin/jellyfin:latest
    container_name: jellyfin
    network_mode: host
    user: '1000:1000'
    volumes:
      - /media/jellyfin-config:/config
      - /media/movies:/movies
      - /media/tvshows:/tvshows
    restart: unless-stopped
    environment:
      - TZ=\$(cat /etc/timezone)
EOF
"

# === Levantar contenedor Docker ===
echo "🎬 Iniciando Jellyfin..."
pct exec $CT_ID -- bash -c "
cd /root && docker-compose up -d
"

echo "🎉 ¡Jellyfin está listo!"
echo "Accede desde: http://<tu-ip-host>:8096"
echo "Directorios montados:"
echo "- Películas: $MOVIES_DIR"
echo "- Series: $TVSHOWS_DIR"
echo "- Configuración: $CONFIG_DIR"
