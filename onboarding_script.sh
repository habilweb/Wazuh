#!/bin/bash

# ==============================================================================
# Script de Despliegue de Agentes de Seguridad para SISBolivia.com
#
# Versión: 1.0
# Autor: Hans Gallardo (con la ayuda de Gemini)
#
# Este script automatiza la instalación y configuración de:
#   1. Suricata (Sistema de Detección de Intrusiones en Red)
#   2. El Agente de Wazuh (Plataforma de Detección y Respuesta)
#   3. La integración entre ambos.
#
# Es compatible con sistemas basados en Debian (Ubuntu) y RHEL (AlmaLinux).
# ==============================================================================

# --- Configuración ---
# Dirección de tu Wazuh Manager. ¡Asegúrate de que este valor sea correcto!
WAZUH_MANAGER_ADDRESS="wazuh.sisbolivia.com"

# --- Funciones de Utilidad ---
# Función para imprimir mensajes informativos
log_info() {
    echo "INFO: $1"
}

# Función para imprimir mensajes de error y salir
log_error() {
    echo "ERROR: $1"
    exit 1
}

# --- Inicio del Script ---
log_info "Iniciando el script de despliegue de agentes de seguridad..."

# Verificar que el script se ejecuta como root
if [ "$(id -u)" -ne 0 ]; then
    log_error "Este script debe ser ejecutado como root o con sudo."
fi

# 1. Detección del Sistema Operativo
OS_ID=""
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID=$ID
else
    log_error "No se pudo detectar el sistema operativo."
fi

log_info "Sistema operativo detectado: $OS_ID"

# 2. Detección de la Interfaz de Red Principal
INTERFACE=$(ip -o -4 route show to default | awk '{print $5}')
if [ -z "$INTERFACE" ]; then
    log_error "No se pudo detectar automáticamente la interfaz de red principal. Edita este script y define la variable INTERFACE manualmente."
fi
log_info "Interfaz de red principal detectada: $INTERFACE"

# 3. Lógica de Instalación y Configuración
if [ "$OS_ID" = "ubuntu" ] || [ "$OS_ID" = "debian" ]; then
    # --- Lógica para Ubuntu/Debian ---
    log_info "Ejecutando la instalación para Ubuntu/Debian..."
    
    # Actualizar el sistema
    apt-get update -y
    
    # Instalar Suricata
    log_info "Instalando Suricata..."
    apt-get install software-properties-common -y
    add-apt-repository ppa:oisf/suricata-stable -y
    apt-get update -y
    apt-get install suricata -y
    
    # Configurar Suricata
    log_info "Configurando Suricata para la interfaz $INTERFACE..."
    sed -i "s/interface: eth0/interface: $INTERFACE/" /etc/suricata/suricata.yaml
    
    # Actualizar reglas de Suricata
    log_info "Actualizando las reglas de Suricata..."
    suricata-update
    
    # Iniciar y habilitar Suricata
    systemctl start suricata
    systemctl enable suricata
    log_info "Suricata instalado y corriendo."
    
    # Instalar Agente de Wazuh
    log_info "Instalando el Agente de Wazuh..."
    curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH | gpg --dearmor | tee /usr/share/keyrings/wazuh-keyring.gpg > /dev/null
    echo "deb [signed-by=/usr/share/keyrings/wazuh-keyring.gpg] https://packages.wazuh.com/4.x/apt/ stable main" | tee -a /etc/apt/sources.list.d/wazuh.list
    apt-get update -y
    WAZUH_MANAGER=$WAZUH_MANAGER_ADDRESS apt-get install wazuh-agent -y
    
elif [ "$OS_ID" = "almalinux" ] || [ "$OS_ID" = "centos" ] || [ "$OS_ID" = "rhel" ]; then
    # --- Lógica para AlmaLinux/RHEL/CentOS ---
    log_info "Ejecutando la instalación para AlmaLinux/RHEL..."
    
    # Actualizar el sistema
    dnf update -y
    
    # Instalar Suricata
    log_info "Instalando Suricata..."
    dnf install epel-release -y
    dnf install suricata -y
    
    # Configurar Suricata
    log_info "Configurando Suricata para la interfaz $INTERFACE..."
    sed -i "s/interface: eth0/interface: $INTERFACE/" /etc/suricata/suricata.yaml
    
    # Actualizar reglas de Suricata
    log_info "Actualizando las reglas de Suricata..."
    suricata-update
    
    # Iniciar y habilitar Suricata
    systemctl start suricata
    systemctl enable suricata
    log_info "Suricata instalado y corriendo."
    
    # Instalar Agente de Wazuh
    log_info "Instalando el Agente de Wazuh..."
    rpm --import https://packages.wazuh.com/key/GPG-KEY-WAZUH
    tee /etc/yum.repos.d/wazuh.repo <<EOF
[wazuh]
gpgcheck=1
gpgkey=https://packages.wazuh.com/key/GPG-KEY-WAZUH
enabled=1
name=Wazuh repository
baseurl=https://packages.wazuh.com/4.x/yum/
protect=1
EOF
    WAZUH_MANAGER=$WAZUH_MANAGER_ADDRESS dnf install wazuh-agent -y

else
    log_error "Sistema operativo no soportado: $OS_ID. Este script solo soporta Ubuntu/Debian y AlmaLinux/RHEL."
fi

# 4. Integración de Suricata con el Agente de Wazuh (Común para ambos sistemas)
log_info "Integrando Suricata con el Agente de Wazuh..."
cat >> /var/ossec/etc/ossec.conf << EOF

<!-- Integración con Suricata -->
<localfile>
  <log_format>json</log_format>
  <location>/var/log/suricata/eve.json</location>
</localfile>
EOF

# 5. Corrección de Permisos
log_info "Ajustando permisos para que el agente de Wazuh pueda leer los logs de Suricata..."
usermod -a -G suricata wazuh

# 6. Iniciar y Habilitar el Agente de Wazuh
log_info "Iniciando y habilitando el Agente de Wazuh..."
systemctl daemon-reload
systemctl enable wazuh-agent
systemctl start wazuh-agent

log_info "--- ¡Despliegue completado con éxito! ---"
log_info "El agente debería aparecer en tu dashboard de Wazuh en unos minutos."
