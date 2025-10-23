#!/bin/bash
# ==============================================================================
# SISBolivia - Onboarding de Agente de Seguridad (v2.5)
# ------------------------------------------------------------------------------

WAZUH_MANAGER_ADDRESS="wazuh.sisbolivia.com"

# --- Utilidades ---
log() { echo -e "\033[1;32m[INFO]\033[0m $1"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $1"; exit 1; }

# --- Verificar root ---
[ "$(id -u)" -ne 0 ] && error "Debe ejecutar este script como root."

# --- Detectar OS ---
if [ -f /etc/os-release ]; then
  . /etc/os-release
  OS=$ID
else
  error "No se pudo detectar el sistema operativo."
fi
log "Sistema operativo detectado: $OS"

# --- Verificar conectividad con el Manager ---
if ping -c 1 -W 3 "$WAZUH_MANAGER_ADDRESS" >/dev/null 2>&1; then
  log "Conectividad con el Manager OK ($WAZUH_MANAGER_ADDRESS)"
else
  warn "No se pudo contactar con $WAZUH_MANAGER_ADDRESS. Verifique red o DNS."
fi

# --- Detectar interfaz principal ---
IFACE=$(ip -o -4 route show to default | awk '{print $5}')
[ -z "$IFACE" ] && error "No se detectó interfaz de red principal."
log "Interfaz de red principal: $IFACE"

# --- Limpieza previa opcional ---
if systemctl list-unit-files | grep -q wazuh-agent.service; then
  warn "Se detecta instalación previa de Wazuh."
  read -p "¿Desea reinstalar desde cero? (y/N): " ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    systemctl stop wazuh-agent 2>/dev/null
    apt purge wazuh-agent -y 2>/dev/null || dnf remove wazuh-agent -y 2>/dev/null
    rm -rf /var/ossec
    log "Instalación previa eliminada."
  fi
fi

# --- Dependencias ---
if [[ "$OS" =~ (ubuntu|debian) ]]; then
  apt-get update -y --allow-releaseinfo-change
  apt-get install -y curl gnupg apt-transport-https software-properties-common
else
  dnf -y update --setopt=exclude=wp-toolkit* --setopt=skip_if_unavailable=True
  dnf install -y curl gnupg2 || yum install -y curl gnupg2
fi

# --- Instalar Wazuh Agent ---
log "Instalando agente Wazuh..."
if [[ "$OS" =~ (ubuntu|debian) ]]; then
  curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH | gpg --dearmor -o /usr/share/keyrings/wazuh.gpg
  echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" > /etc/apt/sources.list.d/wazuh.list
  apt-get update -y
  apt-get install -y wazuh-agent
else
  rpm --import https://packages.wazuh.com/key/GPG-KEY-WAZUH
  cat > /etc/yum.repos.d/wazuh.repo <<EOF
[wazuh]
gpgcheck=1
gpgkey=https://packages.wazuh.com/key/GPG-KEY-WAZUH
enabled=1
name=Wazuh repository
baseurl=https://packages.wazuh.com/4.x/yum/
EOF
  dnf install -y wazuh-agent --setopt=exclude=wp-toolkit*
fi

# --- Corregir Manager IP en configuración ---
CONF="/var/ossec/etc/ossec.conf"
if [ -f "$CONF" ]; then
  sed -i '/<client>/,/<\/client>/d' "$CONF"
fi

cat >> "$CONF" <<EOF
<client>
  <server>
    <address>$WAZUH_MANAGER_ADDRESS</address>
    <port>1514</port>
    <protocol>tcp</protocol>
  </server>
</client>
EOF

# --- Permisos ---
chown -R wazuh:wazuh /var/ossec
chmod -R 750 /var/ossec

# --- Activar y probar servicio ---
log "Iniciando Wazuh Agent..."
systemctl daemon-reexec
systemctl daemon-reload
systemctl enable wazuh-agent
systemctl restart wazuh-agent
sleep 3

if systemctl is-active --quiet wazuh-agent; then
  log "✅ Wazuh Agent iniciado correctamente."
else
  warn "El agente no inició correctamente. Intentando reparación..."
  sed -i "s/MANAGER_IP/$WAZUH_MANAGER_ADDRESS/" "$CONF"
  systemctl restart wazuh-agent
fi

log "Estado actual del agente:"
systemctl status wazuh-agent --no-pager

log "Si todo es correcto, el agente aparecerá en el Dashboard de Wazuh en unos minutos."
