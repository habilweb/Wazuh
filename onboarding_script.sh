#!/bin/bash
# ==============================================================================
# Wazuh Agent + Suricata Deployment Script (v2.6)
# Autor: Hans Gallardo (mejorado con ChatGPT)
# Compatible con: Ubuntu/Debian y RHEL/AlmaLinux
# ==============================================================================

WAZUH_MANAGER="wazuh.sisbolivia.com"

# --- funciones auxiliares ---
log() { echo -e "\033[1;34m[INFO]\033[0m $1"; }
err() { echo -e "\033[1;31m[ERROR]\033[0m $1"; exit 1; }

# --- detección de root ---
[ "$(id -u)" -ne 0 ] && err "Ejecuta este script como root o con sudo."

# --- detectar SO ---
if [ -f /etc/os-release ]; then
  . /etc/os-release
  OS=$ID
else
  err "No se pudo detectar el sistema operativo."
fi
log "Sistema operativo detectado: $OS"

# --- flags ---
INSTALL_SURICATA=false
for arg in "$@"; do
  case $arg in
    --with-suricata) INSTALL_SURICATA=true ;;
  esac
done

# --- modo interactivo si no se pasó flag ---
if [ "$INSTALL_SURICATA" = false ]; then
  read -p "¿Deseas instalar también Suricata? (s/n): " opt
  [[ "$opt" =~ ^[Ss]$ ]] && INSTALL_SURICATA=true
fi

# --- limpiar instalaciones previas ---
if systemctl list-units --type=service | grep -q wazuh-agent; then
  log "Eliminando instalación previa de Wazuh..."
  systemctl stop wazuh-agent 2>/dev/null
  apt-get remove --purge wazuh-agent -y 2>/dev/null || dnf remove -y wazuh-agent 2>/dev/null
  rm -rf /var/ossec /etc/ossec* /etc/systemd/system/wazuh-agent.service
fi

# --- instalación según SO ---
if [[ "$OS" =~ (ubuntu|debian) ]]; then
  log "Actualizando paquetes..."
  apt-get update -y --allow-releaseinfo-change

  log "Instalando dependencias base..."
  apt-get install -y curl gnupg logrotate jq software-properties-common

  log "Agregando repositorio de Wazuh..."
  curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH | gpg --dearmor -o /usr/share/keyrings/wazuh.gpg
  echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" \
    > /etc/apt/sources.list.d/wazuh.list

  apt-get update -y
  log "Instalando Wazuh Agent..."
  WAZUH_MANAGER=$WAZUH_MANAGER apt-get install -y wazuh-agent

elif [[ "$OS" =~ (rhel|centos|almalinux|rocky|cloudlinux) ]]; then
  log "Instalando dependencias base..."
  dnf install -y curl gnupg2 logrotate jq

  log "Agregando repositorio de Wazuh..."
  rpm --import https://packages.wazuh.com/key/GPG-KEY-WAZUH
  cat > /etc/yum.repos.d/wazuh.repo <<EOF
[wazuh]
gpgcheck=1
gpgkey=https://packages.wazuh.com/key/GPG-KEY-WAZUH
enabled=1
name=Wazuh repository
baseurl=https://packages.wazuh.com/4.x/yum/
protect=1
EOF

  log "Instalando Wazuh Agent..."
  WAZUH_MANAGER=$WAZUH_MANAGER dnf install -y wazuh-agent
else
  err "Sistema no soportado: $OS"
fi

# --- suricata opcional ---
if [ "$INSTALL_SURICATA" = true ]; then
  log "Instalando Suricata..."

  if [[ "$OS" =~ (ubuntu|debian) ]]; then
    add-apt-repository ppa:oisf/suricata-stable -y
    apt-get update -y
    apt-get install -y suricata
  else
    dnf install -y epel-release
    dnf install -y suricata
  fi

  IFACE=$(ip -o -4 route show to default | awk '{print $5}')
  [ -z "$IFACE" ] && err "No se pudo detectar interfaz de red principal."

  log "Configurando Suricata en interfaz $IFACE (alert-only)..."
  sed -i "s/interface: .*/interface: $IFACE/" /etc/suricata/suricata.yaml
  sed -i '/types:/,/^ *- / s/^ *- .*/  - alert/' /etc/suricata/suricata.yaml

  suricata-update
  systemctl enable --now suricata

  # rotación de logs
  log "Configurando rotación de logs de Suricata..."
  cat > /etc/logrotate.d/suricata <<EOF
/var/log/suricata/*.log /var/log/suricata/*.json {
    hourly
    rotate 24
    size 50M
    compress
    missingok
    notifempty
    copytruncate
}
EOF

  # integrar con wazuh
  log "Integrando Suricata con Wazuh Agent..."
  grep -q "suricata/eve.json" /var/ossec/etc/ossec.conf || cat >> /var/ossec/etc/ossec.conf <<EOF

<!-- Integración Suricata -->
<localfile>
  <log_format>json</log_format>
  <location>/var/log/suricata/eve.json</location>
</localfile>
EOF
  usermod -a -G suricata wazuh 2>/dev/null
fi

# --- iniciar wazuh ---
log "Habilitando y arrancando Wazuh Agent..."
systemctl daemon-reload
systemctl enable wazuh-agent
systemctl start wazuh-agent || err "Error al iniciar Wazuh Agent."

# --- verificación de conexión ---
log "Verificando conexión con el Manager..."
sleep 5
if timeout 5 bash -c "cat < /dev/null > /dev/tcp/$WAZUH_MANAGER/1514" 2>/dev/null; then
  log "✅ Conexión TCP con $WAZUH_MANAGER OK"
else
  err "❌ No se pudo conectar al Manager $WAZUH_MANAGER en el puerto 1514."
fi

log "Verificando estado del agente..."
sleep 2
systemctl status wazuh-agent --no-pager | grep -E "Active|running" || true

log "✅ Instalación completada exitosamente."
log "Revisa en tu Dashboard de Wazuh que el agente aparezca en línea."
