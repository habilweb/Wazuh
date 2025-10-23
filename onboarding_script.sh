#!/bin/bash
# ==============================================================================
# SISBolivia - Instalador Inteligente de Agentes de Seguridad
#
# Versión: 2.0
# Autor: Hans Gallardo (mejorado con ChatGPT)
# Descripción:
#   Detecta automáticamente el entorno y ajusta la instalación:
#   - Si el servidor tiene >500 GB de espacio → instala Wazuh + Suricata completo
#   - Si tiene <=500 GB → instala solo el agente Wazuh en modo liviano
#   Configura automáticamente la integración, rotación y optimización.
# ==============================================================================

WAZUH_MANAGER="wazuh.sisbolivia.com"

# --- Funciones auxiliares ---
log() { echo -e "\033[1;32m[INFO]\033[0m $1"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $1" >&2; exit 1; }

# --- Verificar ejecución como root ---
if [ "$(id -u)" -ne 0 ]; then error "Debe ejecutar este script como root."; fi

# --- Detectar sistema operativo ---
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

# --- Detectar interfaz de red ---
IFACE=$(ip -o -4 route show to default | awk '{print $5}')
[ -z "$IFACE" ] && error "No se detectó interfaz de red principal."
log "Interfaz de red principal: $IFACE"

# --- Determinar modo de instalación ---
if [ "$DISK_GB" -ge 500 ]; then
    MODE="full"
    log "Modo detectado: FULL (disco >= 500GB). Se instalará Wazuh + Suricata."
else
    MODE="light"
    log "Modo detectado: LIGERO (disco < 500GB). Solo se instalará Wazuh Agent."
fi

# --- Instalar dependencias básicas ---
if [[ "$OS" =~ (ubuntu|debian) ]]; then
    apt-get update -y && apt-get install -y curl gnupg software-properties-common
else
    dnf install -y curl gnupg2 || yum install -y curl gnupg2
fi

# --- Instalar agente Wazuh ---
log "Instalando agente Wazuh..."
if [[ "$OS" =~ (ubuntu|debian) ]]; then
    curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH | gpg --dearmor -o /usr/share/keyrings/wazuh.gpg
    echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" > /etc/apt/sources.list.d/wazuh.list
    apt-get update -y && WAZUH_MANAGER=$WAZUH_MANAGER apt-get install -y wazuh-agent
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
    WAZUH_MANAGER=$WAZUH_MANAGER dnf install -y wazuh-agent
fi

# --- Configuración común de Wazuh Agent ---
log "Configurando agente de Wazuh..."
AGENT_CONF="/var/ossec/etc/ossec.conf"
sed -i '/<localfile>/,/<\/localfile>/d' "$AGENT_CONF"
cat >> "$AGENT_CONF" <<EOF
<!-- Monitoreo básico del sistema -->
<localfile>
  <log_format>syslog</log_format>
  <location>/var/log/syslog</location>
</localfile>
<localfile>
  <log_format>syslog</log_format>
  <location>/var/log/auth.log</location>
</localfile>
EOF

# --- Si modo FULL, instalar Suricata ---
if [ "$MODE" = "full" ]; then
    log "Instalando Suricata (modo completo)..."
    if [[ "$OS" =~ (ubuntu|debian) ]]; then
        add-apt-repository ppa:oisf/suricata-stable -y
        apt-get update -y && apt-get install -y suricata
    else
        dnf install -y epel-release suricata
    fi

    log "Configurando Suricata..."
    sed -i "s/interface: .*/interface: $IFACE/" /etc/suricata/suricata.yaml
    sed -i 's/#* *types:.*/types:\n      - alert/' /etc/suricata/suricata.yaml

    # Rotación de logs para evitar saturación
    cat > /etc/logrotate.d/suricata <<EOF
/var/log/suricata/*.log /var/log/suricata/*.json {
    daily
    rotate 5
    compress
    missingok
    notifempty
}
EOF

    systemctl enable --now suricata
    usermod -a -G suricata wazuh
    cat >> "$AGENT_CONF" <<EOF
<!-- Integración Suricata -->
<localfile>
  <log_format>json</log_format>
  <location>/var/log/suricata/eve.json</location>
</localfile>
EOF
    log "Suricata instalado e integrado correctamente."
else
    log "Modo liviano: Suricata no será instalado en este servidor."
fi

# --- Iniciar agente Wazuh ---
systemctl daemon-reload
systemctl enable wazuh-agent
systemctl restart wazuh-agent

# --- Estado final ---
log "✅ Instalación completada."
log "El agente se conectará automáticamente a: $WAZUH_MANAGER"
if [ "$MODE" = "full" ]; then
    log "Suricata también está corriendo en la interfaz $IFACE con rotación de logs diaria."
else
    log "Solo se instaló el agente Wazuh (modo liviano)."
fi
