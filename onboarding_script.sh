#!/bin/bash
# ==============================================================================
# SISBolivia - Onboarding de Agente de Seguridad (Versión 2.3)
# ------------------------------------------------------------------------------
# Funciones:
#   - Detecta y limpia instalaciones previas de Wazuh Agent
#   - Instala Wazuh Agent + (opcional) Suricata
#   - Compatible con Ubuntu, Debian, AlmaLinux, CloudLinux, CentOS
#   - Evita errores con WordPress Toolkit (--skip wp-toolkit)
# ==============================================================================

WAZUH_MANAGER="wazuh.sisbolivia.com"

# --- Utilidades ---
log() { echo -e "\033[1;32m[INFO]\033[0m $1"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $1"; exit 1; }

# --- Verificar root ---
if [ "$(id -u)" -ne 0 ]; then
  error "Debe ejecutar este script como root."
fi

# --- Detectar OS ---
if [ -f /etc/os-release ]; then
  . /etc/os-release
  OS=$ID
else
  error "No se pudo detectar el sistema operativo."
fi
log "Sistema operativo detectado: $OS"

# --- Detectar espacio disponible ---
DISK_GB=$(df --total -BG --output=size | tail -1 | grep -o '[0-9]\+')
log "Espacio total del servidor: ${DISK_GB} GB"

# --- Detectar interfaz ---
IFACE=$(ip -o -4 route show to default | awk '{print $5}')
[ -z "$IFACE" ] && error "No se detectó interfaz de red principal."
log "Interfaz de red principal: $IFACE"

# --- Verificar si Wazuh Agent ya está instalado ---
if systemctl list-unit-files | grep -q wazuh-agent.service; then
  warn "Ya se detecta una instalación de Wazuh Agent."
  read -p "¿Desea eliminarla completamente antes de reinstalar? (y/N): " answer
  if [[ "$answer" =~ ^[Yy]$ ]]; then
    log "Eliminando instalación previa..."
    systemctl stop wazuh-agent 2>/dev/null
    apt purge wazuh-agent -y 2>/dev/null || dnf remove wazuh-agent -y 2>/dev/null
    rm -rf /var/ossec
    log "Instalación previa de Wazuh limpiada correctamente."
  else
    log "Se conservará la instalación existente. El script solo actualizará configuración."
  fi
fi

# --- Dependencias comunes ---
if [[ "$OS" =~ (ubuntu|debian) ]]; then
  apt-get update -y --allow-releaseinfo-change
  apt-get install -y curl gnupg software-properties-common
else
  dnf -y update --skip-broken --setopt=skip_if_unavailable=True --setopt=exclude=wp-toolkit*
  dnf install -y curl gnupg2 || yum install -y curl gnupg2
fi

# --- Instalar agente Wazuh ---
log "Instalando agente Wazuh..."
if [[ "$OS" =~ (ubuntu|debian) ]]; then
  curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH | gpg --dearmor -o /usr/share/keyrings/wazuh.gpg
  echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" > /etc/apt/sources.list.d/wazuh.list
  apt-get update -y
  WAZUH_MANAGER=$WAZUH_MANAGER apt-get install -y wazuh-agent
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
  WAZUH_MANAGER=$WAZUH_MANAGER dnf install -y wazuh-agent --skip-broken --setopt=exclude=wp-toolkit*
fi

# --- Configurar Wazuh ---
log "Configurando agente Wazuh..."
CONF="/var/ossec/etc/ossec.conf"
if [ -f "$CONF" ]; then
  sed -i '/<localfile>/,/<\/localfile>/d' "$CONF"
fi
cat >> "$CONF" <<EOF
<!-- Logs del sistema -->
<localfile>
  <log_format>syslog</log_format>
  <location>/var/log/syslog</location>
</localfile>
<localfile>
  <log_format>syslog</log_format>
  <location>/var/log/auth.log</location>
</localfile>
EOF

# --- Modo Suricata (solo si hay espacio suficiente) ---
if [ "$DISK_GB" -ge 500 ]; then
  log "Servidor con espacio amplio detectado (${DISK_GB} GB). Instalando Suricata..."
  if [[ "$OS" =~ (ubuntu|debian) ]]; then
    add-apt-repository -y ppa:oisf/suricata-stable
    apt-get update -y && apt-get install -y suricata
  else
    dnf install -y epel-release suricata --setopt=exclude=wp-toolkit*
  fi

  sed -i "s/interface: .*/interface: $IFACE/" /etc/suricata/suricata.yaml
  sed -i 's/#* *types:.*/types:\n      - alert/' /etc/suricata/suricata.yaml

  cat > /etc/logrotate.d/suricata <<EOF
/var/log/suricata/*.log /var/log/suricata/*.json {
  daily
  rotate 5
  compress
  missingok
  notifempty
}
EOF

  usermod -a -G suricata wazuh
  systemctl enable --now suricata
  cat >> "$CONF" <<EOF
<!-- Integración Suricata -->
<localfile>
  <log_format>json</log_format>
  <location>/var/log/suricata/eve.json</location>
</localfile>
EOF
  log "Suricata instalado e integrado con Wazuh."
else
  log "Servidor pequeño (${DISK_GB} GB). Se omite Suricata (modo liviano)."
fi

# --- Activar agente Wazuh ---
systemctl daemon-reload
systemctl enable wazuh-agent
systemctl restart wazuh-agent
sleep 3
systemctl status wazuh-agent --no-pager

log "✅ Instalación completa. El agente debería aparecer en tu dashboard Wazuh en unos minutos."
