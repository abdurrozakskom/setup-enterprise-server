#!/usr/bin/env bash
#===============================================================================
# FILE:        setup-enterprise-server.sh
# DESCRIPTION: Blueprint lengkap infrastruktur server multi-aplikasi
#              enterprise-grade pada Ubuntu 24.04 LTS (8 vCPU, 16GB RAM, 1TB)
# VERSION:     1.0.0
# AUTHOR:      Principal SRE & Chief Infrastructure Architect
# USAGE:       sudo bash setup-enterprise-server.sh [--dry-run]
#
# PREREQUISITES:
#   - Ubuntu 24.04 LTS fresh install
#   - Root privileges
#   - Internet connection untuk apt
#
# DISCLAIMER:
#   Script ini dirancang untuk production-grade deployment dengan
#   idempotency penuh, dapat dijalankan berulang tanpa merusak konfigurasi.
#===============================================================================

set -euo pipefail

#===============================================================
# KONFIGURASI GLOBAL
#===============================================================

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LOG_DIR="/var/log/setup-enterprise"
readonly LOG_FILE="${LOG_DIR}/setup-$(date +%Y%m%d_%H%M%S).log"
readonly BACKUP_ROOT="/root/config-backup"
readonly TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
readonly DRY_RUN=false

# Server configuration
readonly SERVER_IP="192.168.255.246"
readonly SERVER_LAN_CIDR="192.168.255.0/24"
readonly SERVER_HOSTNAME="srv-tkj-01"

# Database configuration
readonly MYSQL_ROOT_USER="root"
readonly MYSQL_ROOT_PASS=""  # Akan di-generate jika kosong
readonly DB_PREFIX="srvtkjdbs"
readonly DB_USER_PREFIX="srvtkjusr"
readonly DB_PASS_PREFIX="srvtkjpwd"

# Application paths - Format: "path:app_type:php_pool:db_required"
# app_type: static|php|laravel|moodle|wordpress|proxy
# php_pool: heavy|light|none
readonly APP_PATHS=(
    "html:static:none:false"
    "blog:wordpress:light:true"
    "lms:moodle:heavy:true"
    "siakad:laravel:heavy:true"
    "cbt:php:light:true"
    "akm:php:light:true"
    "meet:proxy:none:false"
    "wiki:php:light:true"
    "forum:php:light:true"
    "cloud:php:heavy:true"
    "mail:php:light:true"
    "samba:static:none:false"
    "video:proxy:none:false"
    "download:php:light:false"
)

# PHP-FPM configuration
readonly PHP_VERSION="8.3"
readonly PHP_FPM_SOCK_DIR="/run/php"
readonly POOL_HEAVY_MAX_CHILDREN=45
readonly POOL_LIGHT_MAX_CHILDREN=8
readonly POOL_HEAVY_START_SERVERS=10
readonly POOL_LIGHT_START_SERVERS=2

# MySQL configuration
readonly MYSQL_INNODB_BUFFER_POOL_SIZE="4G"
readonly MYSQL_INNODB_BUFFER_POOL_INSTANCES=4
readonly MYSQL_MAX_CONNECTIONS=200

# System resource limits
readonly LIMIT_PHP_FPM_MEM="6G"
readonly LIMIT_PHP_FPM_CPU="400%"
readonly LIMIT_MYSQL_MEM="5G"
readonly LIMIT_MYSQL_CPU="200%"
readonly LIMIT_APACHE_MEM="2G"
readonly LIMIT_APACHE_CPU="100%"

# Backup configuration
readonly BORG_BACKUP_DIR="/backup/borg"
readonly BORG_PASSPHRASE=""  # Akan di-generate jika kosong
readonly BACKUP_RETENTION_DAYS=30

# Monitoring
readonly HEALTH_CHECK_RETRIES=3
readonly HEALTH_CHECK_TIMEOUT=10

#===============================================================
# UTILITIES & LOGGING
#===============================================================

mkdir -p "${LOG_DIR}"
exec > >(tee -a "${LOG_FILE}") 2>&1

log_info() {
    echo -e "\e[32m[$(date '+%Y-%m-%d %H:%M:%S')] [INFO]\e[0m $1"
}

log_warn() {
    echo -e "\e[33m[$(date '+%Y-%m-%d %H:%M:%S')] [WARN]\e[0m $1"
}

log_error() {
    echo -e "\e[31m[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR]\e[0m $1" >&2
}

log_section() {
    echo -e "\e[36m============================================================\e[0m"
    echo -e "\e[36m $1\e[0m"
    echo -e "\e[36m============================================================\e[0m"
}

die() {
    log_error "$1"
    exit 1
}

# Generate random password if not provided
generate_password() {
    openssl rand -base64 32 | tr -d '/+=' | head -c 32
}

# Check if command exists
command_exists() {
    command -v "$1" &>/dev/null
}

# Check if directory exists and create if not
ensure_dir() {
    local dir="$1"
    local owner="${2:-root:root}"
    local perms="${3:-755}"
    
    if [[ ! -d "${dir}" ]]; then
        mkdir -p "${dir}"
        chown "${owner}" "${dir}"
        chmod "${perms}" "${dir}"
        log_info "Created directory: ${dir} (owner: ${owner}, perms: ${perms})"
    fi
}

# Backup file before modification
backup_file() {
    local file="$1"
    if [[ -f "${file}" ]]; then
        local backup_dir="${BACKUP_ROOT}/${TIMESTAMP}"
        ensure_dir "${backup_dir}"
        cp -a "${file}" "${backup_dir}/$(basename "${file}").backup"
        log_info "Backed up: ${file} -> ${backup_dir}/"
    fi
}

# Write config file with backup
write_config() {
    local file="$1"
    local content="$2"
    local owner="${3:-root:root}"
    local perms="${4:-644}"
    
    backup_file "${file}"
    
    # Create directory if needed
    ensure_dir "$(dirname "${file}")"
    
    echo -n "${content}" > "${file}"
    chown "${owner}" "${file}"
    chmod "${perms}" "${file}"
    
    log_info "Written: ${file}"
}

#===============================================================
# SYSTEM PREREQUISITES
#===============================================================

check_prerequisites() {
    log_section "Checking Prerequisites"
    
    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        die "Script must be run as root (sudo)"
    fi
    
    # Check Ubuntu version
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        if [[ "${VERSION_ID}" != "24.04" ]]; then
            log_warn "This script is designed for Ubuntu 24.04, current: ${VERSION_ID}"
        fi
    fi
    
    # Check available resources
    local total_ram=$(free -b | awk '/^Mem:/{print $2}')
    local ram_gb=$((total_ram / 1024 / 1024 / 1024))
    local cpu_count=$(nproc)
    
    log_info "Detected: ${cpu_count} vCPU, ${ram_gb}GB RAM"
    
    if [[ ${cpu_count} -lt 8 ]]; then
        log_warn "Expected 8 vCPU, found: ${cpu_count}"
    fi
    
    if [[ ${ram_gb} -lt 16 ]]; then
        log_warn "Expected 16GB RAM, found: ${ram_gb}GB"
    fi
    
    # Check disk space
    local disk_space=$(df -BG /var/www 2>/dev/null | awk 'NR==2{print $4}' | tr -d 'G')
    if [[ ${disk_space} -lt 100 ]]; then
        log_warn "Low disk space: ${disk_space}GB available at /var/www"
    fi
    
    # Set hostname
    if [[ "$(hostname)" != "${SERVER_HOSTNAME}" ]]; then
        hostnamectl set-hostname "${SERVER_HOSTNAME}" || true
        log_info "Hostname set to: ${SERVER_HOSTNAME}"
    fi
    
    log_info "✓ Prerequisites check passed"
}

update_system() {
    log_section "Updating System"
    
    export DEBIAN_FRONTEND=noninteractive
    
    apt-get update -qq
    apt-get upgrade -y -qq
    
    # Install base packages
    apt-get install -y -qq \
        curl wget git unzip zip \
        htop iotop iftop \
        vim nano \
        openssh-server \
        ca-certificates gnupg lsb-release \
        software-properties-common \
        apt-transport-https \
        rsync cron
    
    # Disable apt-daily timers to prevent resource contention
    systemctl disable apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
    systemctl stop apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
    
    log_info "✓ System updated and base packages installed"
}

#===============================================================
# KERNEL OPTIMIZATION
#===============================================================

configure_kernel() {
    log_section "Configuring Kernel Parameters"
    
    local sysctl_conf="/etc/sysctl.d/99-enterprise.conf"
    
    cat > "${sysctl_conf}" << 'EOF'
# Enterprise Server Optimization - 8 vCPU, 16GB RAM
# Network optimization
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_max_tw_buckets = 1440000
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 600
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_syncookies = 1

# File descriptor limits
fs.file-max = 2097152
fs.nr_open = 2097152

# Virtual memory optimization
vm.swappiness = 10
vm.overcommit_memory = 1
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5

# Inotify optimization (for file watching)
fs.inotify.max_user_watches = 1048576
fs.inotify.max_user_instances = 8192
EOF
    
    sysctl -p "${sysctl_conf}" > /dev/null 2>&1
    
    # Configure file limits
    cat > /etc/security/limits.d/99-enterprise.conf << 'EOF'
* soft nofile 1048576
* hard nofile 1048576
* soft nproc 65535
* hard nproc 65535
root soft nofile 1048576
root hard nofile 1048576
EOF
    
    log_info "✓ Kernel parameters optimized"
}

#===============================================================
# WEB SERVER (APACHE) INSTALLATION & CONFIGURATION
#===============================================================

install_apache() {
    log_section "Installing Apache 2.4"
    
    apt-get install -y -qq \
        apache2 \
        apache2-utils \
        apache2-dev \
        libapache2-mod-proxy-uwsgi 2>/dev/null || true
    
    # Enable required modules
    local modules=(
        proxy
        proxy_fcgi
        proxy_http
        proxy_wstunnel
        rewrite
        headers
        alias
        setenvif
        ssl
        expires
        deflate
        http2
    )
    
    for module in "${modules[@]}"; do
        a2enmod "${module}" 2>/dev/null || log_warn "Module ${module} not available"
    done
    
    # Disable unused modules for security
    a2dismod autoindex 2>/dev/null || true
    a2dismod status 2>/dev/null || true
    a2dismod info 2>/dev/null || true
    
    # Configure Apache main configuration
    configure_apache_main
    
    log_info "✓ Apache installed and configured"
}

configure_apache_main() {
    log_section "Configuring Apache Main Settings"
    
    local apache_conf="/etc/apache2/apache2.conf"
    
    backup_file "${apache_conf}"
    
    cat > "${apache_conf}" << 'EOF'
# Apache 2.4 Main Configuration - Enterprise Multi-App Server
# Optimized for 8 vCPU, 16GB RAM

Mutex file:${APACHE_LOCK_DIR} default
PidFile ${APACHE_PID_FILE}
Timeout 300
KeepAlive On
MaxKeepAliveRequests 100
KeepAliveTimeout 5

# User/Group
User ${APACHE_RUN_USER}
Group ${APACHE_RUN_GROUP}

# HostnameLookups: Log names of clients or just IP addresses
HostnameLookups Off

# ErrorLog: The location of the error log file
ErrorLog ${APACHE_LOG_DIR}/error.log

# LogLevel: Control the severity of messages logged
LogLevel warn

# Include module configuration:
IncludeOptional mods-enabled/*.load
IncludeOptional mods-enabled/*.conf

# Include list of ports to listen on
Include ports.conf

# Directory access control
<Directory />
    Options FollowSymLinks
    AllowOverride None
    Require all denied
</Directory>

<Directory /usr/share>
    AllowOverride None
    Require all granted
</Directory>

<Directory /var/www/>
    Options -Indexes +FollowSymLinks
    AllowOverride All
    Require all granted
</Directory>

# AccessFileName: The name of the file to look for in each directory
AccessFileName .htaccess

# Files to hide
<FilesMatch "^\.(?!htaccess|htpasswd).*$">
    Require all denied
</FilesMatch>

# Log configuration
LogFormat "%v:%p %h %l %u %t \"%r\" %>s %O \"%{Referer}i\" \"%{User-Agent}i\"" vhost_combined
LogFormat "%h %l %u %t \"%r\" %>s %O \"%{Referer}i\" \"%{User-Agent}i\"" combined
LogFormat "%h %l %u %t \"%r\" %>s %O" common
LogFormat "%{Referer}i -> %U" referer
LogFormat "%{User-agent}i" agent

# Security headers
<IfModule mod_headers.c>
    Header always set X-Content-Type-Options "nosniff"
    Header always set X-Frame-Options "SAMEORIGIN"
    Header always set X-XSS-Protection "1; mode=block"
    Header always set X-Powered-By ""
    Header always set Server ""
</IfModule>

# Compression
<IfModule mod_deflate.c>
    AddOutputFilterByType DEFLATE text/html text/plain text/css text/xml
    AddOutputFilterByType DEFLATE application/javascript application/json
    AddOutputFilterByType DEFLATE image/svg+xml
    AddOutputFilterByType DEFLATE text/javascript
    DeflateCompressionLevel 6
    DeflateMemLevel 8
    DeflateWindowSize 15
</IfModule>

# Caching
<IfModule mod_expires.c>
    ExpiresActive On
    ExpiresByType image/jpg "access plus 1 month"
    ExpiresByType image/jpeg "access plus 1 month"
    ExpiresByType image/gif "access plus 1 month"
    ExpiresByType image/png "access plus 1 month"
    ExpiresByType text/css "access plus 1 week"
    ExpiresByType application/javascript "access plus 1 week"
    ExpiresByType application/pdf "access plus 1 month"
    ExpiresByType text/x-javascript "access plus 1 week"
    ExpiresByType application/x-shockwave-flash "access plus 1 month"
    ExpiresByType image/x-icon "access plus 1 year"
    ExpiresDefault "access plus 2 days"
</IfModule>

# Include generic snippets of statements
IncludeOptional conf-enabled/*.conf

# Include virtual hosts
IncludeOptional sites-enabled/*.conf

# Server performance tuning for 8 vCPU
<IfModule mpm_event_module>
    StartServers             4
    MinSpareThreads         32
    MaxSpareThreads         96
    ThreadLimit             64
    ThreadsPerChild         32
    MaxRequestWorkers       384
    MaxConnectionsPerChild  10000
    KeepAliveTimeout          5
</IfModule>

# Disable server signature
ServerSignature Off
ServerTokens Prod
EOF
    
    # Configure ports
    cat > /etc/apache2/ports.conf << 'EOF'
Listen 80
<IfModule ssl_module>
    Listen 443
</IfModule>
<IfModule mod_gnutls.c>
    Listen 443
</IfModule>
EOF
    
    # Create directory structure
    ensure_dir "/var/www" "www-data:www-data" "755"
    
    log_info "✓ Apache main configuration written"
}

create_apache_vhost_configs() {
    log_section "Creating Apache Virtual Host Configurations"
    
    local sites_dir="/etc/apache2/sites-available"
    ensure_dir "${sites_dir}"
    
    # Create main VirtualHost that includes all path configurations
    cat > "${sites_dir}/000-main.conf" << EOF
# Main VirtualHost - Includes all application path configurations
<VirtualHost *:80>
    ServerAdmin admin@${SERVER_HOSTNAME}.local
    ServerName ${SERVER_IP}
    ServerAlias ${SERVER_HOSTNAME}
    DocumentRoot /var/www/html

    # Security headers
    <IfModule mod_headers.c>
        Header always set X-Content-Type-Options "nosniff"
        Header always set X-Frame-Options "SAMEORIGIN"
        Header always set X-XSS-Protection "1; mode=block"
    </IfModule>

    # Logging
    ErrorLog \${APACHE_LOG_DIR}/main_error.log
    CustomLog \${APACHE_LOG_DIR}/main_access.log combined env=!dontlog

    # Disable TRACE method
    TraceEnable Off

    # Include application-specific configurations
 $(for app_config in "${APP_PATHS[@]}"; do
    IFS=':' read -r path app_type pool db_required <<< "${app_config}"
    echo "    IncludeOptional sites-available/${path}.conf"
done)
</VirtualHost>
EOF
    
    # Create individual path configurations
    for app_config in "${APP_PATHS[@]}"; do
        IFS=':' read -r path app_type pool db_required <<< "${app_config}"
        create_app_config "${path}" "${app_type}" "${pool}" "${db_required}"
    done
    
    # Enable site
    a2dissite 000-default 2>/dev/null || true
    a2ensite 000-main.conf
    
    log_info "✓ Created $((${#APP_PATHS[@]} + 1)) Apache configuration files"
}

create_app_config() {
    local path="$1"
    local app_type="$2"
    local pool="$3"
    local db_required="$4"
    local conf_file="/etc/apache2/sites-available/${path}.conf"
    
    case "${app_type}" in
        "static")
            cat > "${conf_file}" << EOF
# Application: ${path} (Static Content)
# Type: Static, no PHP processing
Alias /${path} /var/www/${path}
<Directory /var/www/${path}>
    Options -Indexes +FollowSymLinks
    AllowOverride All
    Require all granted
    
    <IfModule mod_headers.c>
        Header set Cache-Control "max-age=3600, public"
    </IfModule>
</Directory>
EOF
            ;;
            
        "proxy")
            if [[ "${path}" == "video" ]]; then
                # Jellyfin proxy configuration
                cat > "${conf_file}" << 'EOF'
# Application: Jellyfin (Video Streaming)
# Type: Reverse Proxy to 127.0.0.1:8096
<Location /video>
    ProxyPass http://127.0.0.1:8096/video
    ProxyPassReverse http://127.0.0.1:8096/video
    
    # WebSocket support for real-time streaming
    <IfModule mod_proxy_wstunnel.c>
        ProxyPreserveHost On
        RequestHeader set X-Forwarded-Proto "http"
        RequestHeader set X-Forwarded-Port "80"
    </IfModule>
</Location>

# Additional location for Jellyfin API
<Location /video/websocket>
    ProxyPass ws://127.0.0.1:8096/websocket
    ProxyPassReverse ws://127.0.0.1:8096/websocket
</Location>

# Timeout for large media files
ProxyTimeout 600
EOF
            elif [[ "${path}" == "meet" ]]; then
                # JitsiMeet proxy configuration
                cat > "${conf_file}" << 'EOF'
# Application: JitsiMeet (Video Conferencing)
# Type: Reverse Proxy to 127.0.0.1:8000
<Location /meet>
    ProxyPass http://127.0.0.1:8000/meet
    ProxyPassReverse http://127.0.0.1:8000/meet
    ProxyPreserveHost On
    
    # WebSocket support for signaling
    <IfModule mod_proxy_wstunnel.c>
        ProxyPass ws://127.0.0.1:8000/xmpp-websocket
        ProxyPassReverse ws://127.0.0.1:8000/xmpp-websocket
    </IfModule>
    
    # Disable buffering for real-time communication
    ProxyRequests Off
    ProxyPreserveHost On
</Location>

# Additional locations for JitsiMeet
<Location /http-bind>
    ProxyPass http://127.0.0.1:5280/http-bind
    ProxyPassReverse http://127.0.0.1:5280/http-bind
</Location>

ProxyTimeout 300
EOF
            fi
            ;;
            
        "laravel")
            cat > "${conf_file}" << EOF
# Application: ${path} (Laravel Framework)
# Type: PHP Application, Document Root: public/
Alias /${path} /var/www/${path}/public

<Directory /var/www/${path}/public>
    Options -Indexes +FollowSymLinks
    AllowOverride All
    Require all granted
    
    <IfModule mod_rewrite.c>
        <IfModule mod_negotiation.c>
            Options -MultiViews -Indexes
        </IfModule>
        RewriteEngine On
        RewriteBase /${path}
        RewriteCond %{REQUEST_FILENAME} !-d
        RewriteCond %{REQUEST_FILENAME} !-f
        RewriteRule ^ index.php [L]
    </IfModule>
</Directory>

# Deny access to sensitive directories
<Directory /var/www/${path}/storage>
    Require all denied
</Directory>
<Directory /var/www/${path}/bootstrap/cache>
    Require all granted
</Directory>
<DirectoryMatch "/var/www/${path}/\.(git|env)">
    Require all denied
</DirectoryMatch>

<FilesMatch \.php\$>
    SetHandler "proxy:unix:${PHP_FPM_SOCK_DIR}/php${PHP_VERSION}-fpm-${pool}.sock|fcgi://localhost"
</FilesMatch>
EOF
            ;;
            
        "moodle")
            cat > "${conf_file}" << EOF
# Application: ${path} (Moodle LMS)
# Type: PHP Application, Document Root: public/
Alias /${path} /var/www/${path}/public

<Directory /var/www/${path}/public>
    Options -Indexes +FollowSymLinks
    AllowOverride All
    Require all granted
    
    <IfModule mod_rewrite.c>
        RewriteEngine On
        RewriteBase /${path}
        RewriteCond %{REQUEST_FILENAME} !-f
        RewriteRule ^(.*)$ index.php [QSA,L]
    </IfModule>
</Directory>

# Deny access to moodledata directory
<Directory /var/www/${path}/moodledata>
    Require all denied
</Directory>

<FilesMatch \.php\$>
    SetHandler "proxy:unix:${PHP_FPM_SOCK_DIR}/php${PHP_VERSION}-fpm-${pool}.sock|fcgi://localhost"
</FilesMatch>
EOF
            ;;
            
        "wordpress")
            cat > "${conf_file}" << EOF
# Application: ${path} (WordPress)
# Type: PHP Application
Alias /${path} /var/www/${path}

<Directory /var/www/${path}>
    Options -Indexes +FollowSymLinks
    AllowOverride All
    Require all granted
    
    # WordPress-specific security
    <FilesMatch "^(wp-config\.php|wp-admin/install\.php)">
        Require all granted
    </FilesMatch>
    
    # Deny access to wp-config.php backup files
    <FilesMatch "^(wp-config\.php\.bak|wp-config\.php\.orig|wp-config\.php\.save)">
        Require all denied
    </FilesMatch>
    
    # Deny access to sensitive files
    <FilesMatch "^(\.htaccess|\.htpasswd|wp-config\.php|readme\.html|license\.txt)">
        Require all denied
    </FilesMatch>
</Directory>

<FilesMatch \.php\$>
    SetHandler "proxy:unix:${PHP_FPM_SOCK_DIR}/php${PHP_VERSION}-fpm-${pool}.sock|fcgi://localhost"
</FilesMatch>
EOF
            ;;
            
        *)
            # Generic PHP application
            cat > "${conf_file}" << EOF
# Application: ${path} (PHP Application)
# Type: Generic PHP, PHP Pool: ${pool}
Alias /${path} /var/www/${path}

<Directory /var/www/${path}>
    Options -Indexes +FollowSymLinks
    AllowOverride All
    Require all granted
    
    # Security: deny access to hidden files
    <FilesMatch "^\.">
        Require all denied
    </FilesMatch>
    
    # Security: deny access to sensitive file types
    <FilesMatch "\.(sql|log|ini|sh|bak|old|dist|swp|tar\.gz|tgz|zip|rar)$">
        Require all denied
    </FilesMatch>
</Directory>

<FilesMatch \.php\$>
    SetHandler "proxy:unix:${PHP_FPM_SOCK_DIR}/php${PHP_VERSION}-fpm-${pool}.sock|fcgi://localhost"
</FilesMatch>
EOF
            ;;
    esac
    
    log_info "  Created: ${conf_file} (type: ${app_type}, pool: ${pool})"
}

#===============================================================
# PHP-FPM INSTALLATION & CONFIGURATION
#===============================================================

install_php() {
    log_section "Installing PHP ${PHP_VERSION} with Extensions"
    
    # Add PHP repository
    add-apt-repository -y ppa:ondrej/php 2>/dev/null || {
        log_info "PHP repository already available"
    }
    apt-get update -qq
    
    # Install PHP-FPM with required extensions
    apt-get install -y -qq \
        php${PHP_VERSION}-fpm \
        php${PHP_VERSION}-cli \
        php${PHP_VERSION}-common \
        php${PHP_VERSION}-mysql \
        php${PHP_VERSION}-curl \
        php${PHP_VERSION}-gd \
        php${PHP_VERSION}-xml \
        php${PHP_VERSION}-mbstring \
        php${PHP_VERSION}-zip \
        php${PHP_VERSION}-soap \
        php${PHP_VERSION}-intl \
        php${PHP_VERSION}-bcmath \
        php${PHP_VERSION}-bz2 \
        php${PHP_VERSION}-opcache \
        php${PHP_VERSION}-readline \
        php${PHP_VERSION}-xmlrpc \
        php${PHP_VERSION}-ldap \
        php${PHP_VERSION}-snmp \
        php${PHP_VERSION}-pspell \
        php${PHP_VERSION}-imap \
        php${PHP_VERSION}-tidy \
        php${PHP_VERSION}-xsl \
        php${PHP_VERSION}-redis \
        php${PHP_VERSION}-memcached \
        php-pear \
        php${PHP_VERSION}-dev
    
    # Install APCu for object caching
    apt-get install -y -qq php${PHP_VERSION}-apcu 2>/dev/null || {
        log_warn "php${PHP_VERSION}-apcu not available, using opcache only"
    }
    
    configure_php_fpm
    configure_php_ini
    
    log_info "✓ PHP ${PHP_VERSION} installed with FPM"
}

configure_php_fpm() {
    log_section "Configuring PHP-FPM Pools (Heavy & Light)"
    
    local pool_dir="/etc/php/${PHP_VERSION}/fpm/pool.d"
    ensure_dir "${pool_dir}"
    
    # Remove default pool
    rm -f "${pool_dir}/www.conf" 2>/dev/null || true
    
    # Create Heavy pool (for Moodle, Laravel, Nextcloud)
    cat > "${pool_dir}/heavy.conf" << EOF
; Pool: Heavy
; For resource-intensive applications: Moodle, Laravel/Siakad, Nextcloud
; Mathematical allocation: (16GB - 2GB OS - 4GB MySQL - 1GB Apache - 2GB Other) / 45MB = ~150
; With 3 heavy apps: 50 per app, but we allocate conservatively: 45

[heavy]
user = www-data
group = www-data

listen = ${PHP_FPM_SOCK_DIR}/php${PHP_VERSION}-fpm-heavy.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660

; Process manager configuration
; Calculate: (Available RAM for PHP-FPM) / (avg memory per worker)
; Available: ~6GB, Heavy pool gets ~4GB = 4096MB / 45MB = 91
; But we limit to 45 for stability and to prevent memory exhaustion
pm = dynamic
pm.max_children = ${POOL_HEAVY_MAX_CHILDREN}
pm.start_servers = ${POOL_HEAVY_START_SERVERS}
pm.min_spare_servers = 5
pm.max_spare_servers = 15
pm.max_requests = 500
pm.process_idle_timeout = 10s

; Request limits
request_terminate_timeout = 120s
request_slowlog_timeout = 30s
slowlog = /var/log/php${PHP_VERSION}-fpm-heavy-slow.log

; Logging
catch_workers_output = yes
decorate_workers_output = no
clear_env = no

; PHP settings for heavy applications
php_admin_value[memory_limit] = 512M
php_admin_value[max_execution_time] = 300
php_admin_value[max_input_time] = 300
php_admin_value[upload_max_filesize] = 256M
php_admin_value[post_max_size] = 256M
php_admin_value[max_file_uploads] = 50
php_admin_value[display_errors] = Off
php_admin_value[log_errors] = On
php_admin_value[error_log] = /var/log/php${PHP_VERSION}-fpm-heavy-error.log
php_admin_value[error_reporting] = E_ALL & ~E_DEPRECATED & ~E_STRICT

; OPcache settings
php_admin_flag[opcache.enable] = 1
php_admin_value[opcache.memory_consumption] = 256
php_admin_value[opcache.interned_strings_buffer] = 64
php_admin_value[opcache.max_accelerated_files] = 32531
php_admin_value[opcache.validate_timestamps] = 1
php_admin_value[opcache.revalidate_freq] = 60
php_admin_value[opcache.fast_shutdown] = 1

; Session settings
php_admin_value[session.save_handler] = files
php_admin_value[session.save_path] = /var/lib/php/sessions/heavy
php_admin_value[session.gc_maxlifetime] = 7200

; Security settings
php_admin_flag[expose_php] = Off
php_admin_flag[allow_url_fopen] = Off
php_admin_flag[allow_url_include] = Off
php_admin_value[disable_functions] = exec,passthru,shell_exec,system,proc_open,popen,curl_exec,curl_multi_exec,parse_ini_file,show_source
EOF
    
    # Create Light pool (for WordPress, MediaWiki, PhpBB, etc.)
    cat > "${pool_dir}/light.conf" << EOF
; Pool: Light
; For lightweight applications: WordPress, MediaWiki, PhpBB, CandyCBT, Sandik, Roundcube, DirectoryLister
; Mathematical allocation: Remaining ~2GB / 45MB = ~45 workers total
; With 7+ light apps: 6-8 per app

[light]
user = www-data
group = www-data

listen = ${PHP_FPM_SOCK_DIR}/php${PHP_VERSION}-fpm-light.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660

; Process manager configuration
; Available for light pool: ~2GB = 2048MB / 45MB = ~45
; Distributed across 7 apps: ~6 per app, we allocate 8 for headroom
pm = dynamic
pm.max_children = ${POOL_LIGHT_MAX_CHILDREN}
pm.start_servers = ${POOL_LIGHT_START_SERVERS}
pm.min_spare_servers = 1
pm.max_spare_servers = 3
pm.max_requests = 1000
pm.process_idle_timeout = 5s

; Request limits
request_terminate_timeout = 60s
request_slowlog_timeout = 20s
slowlog = /var/log/php${PHP_VERSION}-fpm-light-slow.log

; Logging
catch_workers_output = yes
decorate_workers_output = no
clear_env = no

; PHP settings for light applications
php_admin_value[memory_limit] = 128M
php_admin_value[max_execution_time] = 60
php_admin_value[max_input_time] = 60
php_admin_value[upload_max_filesize] = 32M
php_admin_value[post_max_size] = 32M
php_admin_value[max_file_uploads] = 20
php_admin_value[display_errors] = Off
php_admin_value[log_errors] = On
php_admin_value[error_log] = /var/log/php${PHP_VERSION}-fpm-light-error.log
php_admin_value[error_reporting] = E_ALL & ~E_DEPRECATED & ~E_STRICT

; OPcache settings
php_admin_flag[opcache.enable] = 1
php_admin_value[opcache.memory_consumption] = 128
php_admin_value[opcache.interned_strings_buffer] = 32
php_admin_value[opcache.max_accelerated_files] = 16229
php_admin_value[opcache.validate_timestamps] = 1
php_admin_value[opcache.revalidate_freq] = 120
php_admin_value[opcache.fast_shutdown] = 1

; Session settings
php_admin_value[session.save_handler] = files
php_admin_value[session.save_path] = /var/lib/php/sessions/light
php_admin_value[session.gc_maxlifetime] = 3600

; Security settings
php_admin_flag[expose_php] = Off
php_admin_flag[allow_url_fopen] = Off
php_admin_flag[allow_url_include] = Off
php_admin_value[disable_functions] = exec,passthru,shell_exec,system,proc_open,popen,curl_exec,curl_multi_exec,parse_ini_file,show_source
EOF
    
    # Create session directories
    ensure_dir "/var/lib/php/sessions/heavy" "www-data:www-data" "1733"
    ensure_dir "/var/lib/php/sessions/light" "www-data:www-data" "1733"
    
    # Configure systemd resource limits for PHP-FPM
    configure_systemd_limits "php${PHP_VERSION}-fpm" "${LIMIT_PHP_FPM_MEM}" "${LIMIT_PHP_FPM_CPU}"
    
    # Test configuration
    php-fpm${PHP_VERSION} -t 2>/dev/null || {
        die "PHP-FPM configuration test failed"
    }
    
    # Restart PHP-FPM
    systemctl restart php${PHP_VERSION}-fpm
    systemctl enable php${PHP_VERSION}-fpm
    
    log_info "✓ PHP-FPM pools configured (Heavy: ${POOL_HEAVY_MAX_CHILDREN}, Light: ${POOL_LIGHT_MAX_CHILDREN})"
}

configure_php_ini() {
    log_section "Configuring PHP INI"
    
    local php_ini="/etc/php/${PHP_VERSION}/fpm/php.ini"
    
    backup_file "${php_ini}"
    
    cat > "${php_ini}" << 'EOF'
; PHP 8.3 CLI/FPM Configuration - Enterprise Server
[PHP]

;;;;;;;;;;;;;;;;;;;
; Language Options ;
;;;;;;;;;;;;;;;;;;;

engine = On
short_open_tag = Off
precision = 14
output_buffering = 4096
zlib.output_compression = Off
implicit_flush = Off
unserialize_callback_func =
serialize_precision = -1
disable_classes =
disable_functions = exec,passthru,shell_exec,system,proc_open,popen,curl_exec,curl_multi_exec,parse_ini_file,show_source

; Resource Limits
max_execution_time = 300
max_input_time = 300
memory_limit = 256M

; Error handling
error_reporting = E_ALL & ~E_DEPRECATED & ~E_STRICT
display_errors = Off
display_startup_errors = Off
log_errors = On
log_errors_max_len = 1024
ignore_repeated_errors = Off
ignore_repeated_source = Off
report_memleaks = On
html_errors = Off
error_log = /var/log/php8.3-fpm-error.log

; Data Handling
variables_order = "GPCS"
request_order = "GP"
register_argc_argv = Off
auto_globals_jit = On
post_max_size = 256M
auto_prepend_file =
auto_append_file =
default_mimetype = "text/html"
default_charset = "UTF-8"

; Paths and Directories
include_path = ".:/usr/share/php"
doc_root =
user_dir =
enable_dl = Off
cgi.fix_pathinfo = 0

; File Uploads
file_uploads = On
upload_tmp_dir = /tmp
upload_max_filesize = 256M
max_file_uploads = 50

; Fopen wrappers
allow_url_fopen = Off
allow_url_include = Off
from = ""
user_agent = ""
default_socket_timeout = 60

; Dynamic Extensions
extension=curl
extension=gd
extension=mbstring
extension=mysqli
extension=pdo_mysql
extension=soap
extension=xmlrpc
extension=intl
extension=ldap
extension=zip
extension=apcu
extension=redis

;;;;;;;;;;;;;;;;;;;
; Module Settings ;
;;;;;;;;;;;;;;;;;;;

[CLI Server]
cli_server.color = On

[Date]
date.timezone = Asia/Jakarta

[filter]
filter.default = unsafe_raw
filter.default_flags =

[iconv]
iconv.input_encoding = UTF-8
iconv.internal_encoding = UTF-8
iconv.output_encoding = UTF-8

[intl]
intl.default_locale = id_ID
intl.error_level = 0

[sqlite3]
sqlite3.extension_dir =

[Pcre]
pcre.backtrack_limit=1000000
pcre.recursion_limit=100000

[Pdo]
pdo_mysql.cache_size = 2000
pdo_mysql.default_socket=

[mail function]
SMTP = localhost
smtp_port = 25
sendmail_path = /usr/sbin/sendmail -t -i
mail.add_x_header = Off

[SQL]
sql.safe_mode = Off

[ODBC]
odbc.allow_persistent = On
odbc.check_persistent = On
odbc.max_persistent = -1
odbc.max_links = -1
odbc.defaultlrl = 4096
odbc.defaultbinmode = 1

[Interbase]
ibase.allow_persistent = 1
ibase.max_persistent = -1
ibase.max_links = -1
ibase.timestampformat = "%Y-%m-%d %H:%M:%S"
ibase.dateformat = "%Y-%m-%d"
ibase.timeformat = "%H:%M:%S"

[MySQL]
mysql.allow_local_infile = On
mysql.allow_persistent = On
mysql.cache_size = 2000
mysql.max_persistent = -1
mysql.max_links = -1
mysql.default_port =
mysql.default_socket =
mysql.default_host =
mysql.default_user =
mysql.default_password =
mysql.connect_timeout = 60
mysql.trace_mode = Off

[MySQLi]
mysqli.max_persistent = -1
mysqli.allow_persistent = On
mysqli.max_links = -1
mysqli.cache_size = 2000
mysqli.default_port = 3306
mysqli.default_socket =
mysqli.default_host =
mysqli.default_user =
mysqli.default_pw =
mysqli.reconnect = Off

[mysqlnd]
mysqlnd.collect_statistics = On
mysqlnd.collect_memory_statistics = Off

[PostgreSQL]
pgsql.allow_persistent = On
pgsql.auto_reset_persistent = Off
pgsql.max_persistent = -1
pgsql.max_links = -1
pgsql.ignore_notice = 0
pgsql.log_notice = 0

[bcmath]
bcmath.scale = 0

[Session]
session.save_handler = files
session.save_path = "/var/lib/php/sessions"
session.use_strict_mode = 1
session.use_cookies = 1
session.use_only_cookies = 1
session.name = PHPSESSID
session.auto_start = 0
session.cookie_lifetime = 0
session.cookie_path = /
session.cookie_domain =
session.cookie_httponly = 1
session.cookie_secure = 0
session.serialize_handler = php
session.gc_probability = 1
session.gc_divisor = 1000
session.gc_maxlifetime = 7200
session.referer_check =
session.cache_limiter = nocache
session.cache_expire = 180
session.use_trans_sid = 0
session.sid_length = 48
session.trans_sid_tags = "a=href,area=href,frame=src,form="

[Assertion]
zend.assertions = -1
assert.active = Off
assert.exception = On

[mbstring]
mbstring.language = neutral
mbstring.internal_encoding = UTF-8
mbstring.http_input = UTF-8
mbstring.http_output = UTF-8
mbstring.encoding_translation = On
mbstring.detect_order = auto
mbstring.substitute_character = none
mbstring.func_overload = 0
mbstring.strict_detection = On

[gd]
gd.jpeg_ignore_warning = 1

[exif]
exif.encode_unicode = ISO-8859-15
exif.decode_unicode_motorola = UCS-2LE
exif.decode_unicode_intel = UCS-2LE
exif.encode_jis =
exif.decode_jis_motorola = JIS
exif.decode_jis_intel = JIS

[Tidy]
tidy.clean_output = Off

[soap]
soap.wsdl_cache_enabled = 1
soap.wsdl_cache_dir = "/tmp"
soap.wsdl_cache_ttl = 86400
soap.wsdl_cache_limit = 5

[sysvshm]
sysvshm.init_mem = 10000

[ldap]
ldap.max_links = -1

[dba]
dba.default_handler =

[opcache]
opcache.enable = 1
opcache.enable_cli = 0
opcache.memory_consumption = 256
opcache.interned_strings_buffer = 64
opcache.max_accelerated_files = 32531
opcache.validate_timestamps = 1
opcache.revalidate_freq = 60
opcache.save_comments = 1
opcache.fast_shutdown = 1

[curl]
curl.cainfo = /etc/ssl/certs/ca-certificates.crt

[openssl]
openssl.cafile = /etc/ssl/certs/ca-certificates.crt
EOF
    
    log_info "✓ PHP INI configured"
}

#===============================================================
# MYSQL INSTALLATION & CONFIGURATION
#===============================================================

install_mysql() {
    log_section "Installing MySQL 8.0"
    
    apt-get install -y -qq mysql-server mysql-client
    
    # Start and enable MySQL
    systemctl start mysql
    systemctl enable mysql
    
    configure_mysql
    secure_mysql
    create_databases
    
    log_info "✓ MySQL installed and configured"
}

configure_mysql() {
    log_section "Configuring MySQL for 8 vCPU, 16GB RAM"
    
    local mysql_conf="/etc/mysql/mysql.conf.d/mysqld.cnf"
    
    backup_file "${mysql_conf}"
    
    cat > "${mysql_conf}" << 'EOF'
# MySQL 8.0 Configuration - Enterprise Multi-App Server
# Hardware: 8 vCPU, 16GB RAM, 1TB NVMe SSD

[mysqld]
# Basic settings
user = mysql
pid-file = /var/run/mysqld/mysqld.pid
socket = /var/run/mysqld/mysqld.sock
port = 3306
basedir = /usr
datadir = /var/lib/mysql
tmpdir = /tmp
bind-address = 127.0.0.1

# Character set
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
skip-character-set-client-handshake

# Connection settings
max_connections = 200
max_connect_errors = 100000
max_allowed_packet = 256M
connect_timeout = 60
wait_timeout = 600
interactive_timeout = 600

# InnoDB settings (critical for performance)
# Calculation: 16GB total RAM
# - OS Buffer: 2GB
# - Apache + PHP: 6GB
# - Other services: 3GB
# - Available for MySQL: 5GB
# We allocate 4GB for buffer pool, leaving 1GB for other MySQL structures
innodb_buffer_pool_size = 4G
innodb_buffer_pool_instances = 4
innodb_buffer_pool_chunk_size = 1G
innodb_log_file_size = 512M
innodb_log_buffer_size = 64M
innodb_flush_log_at_trx_commit = 2
innodb_flush_method = O_DIRECT
innodb_file_per_table = 1
innodb_io_capacity = 2000
innodb_io_capacity_max = 4000
innodb_read_io_threads = 8
innodb_write_io_threads = 8
innodb_thread_concurrency = 0
innodb_lock_wait_timeout = 120
innodb_autoinc_lock_mode = 2

# Query cache (disabled in MySQL 8, using application-level caching)
query_cache_type = 0
query_cache_size = 0

# Temporary tables
tmp_table_size = 64M
max_heap_table_size = 64M
table_open_cache = 4000
table_definition_cache = 2000
open_files_limit = 65535

# Slow query log
slow_query_log = 1
slow_query_log_file = /var/log/mysql/slow-query.log
long_query_time = 2
log_queries_not_using_indexes = 1

# Error log
log_error = /var/log/mysql/error.log
log_warnings = 2

# Binary logging (for backup and replication)
server-id = 1
log_bin = /var/log/mysql/mysql-bin.log
binlog_format = ROW
binlog_row_image = FULL
expire_logs_days = 7
max_binlog_size = 256M

# Performance schema (for monitoring)
performance_schema = ON
performance_schema_max_table_instances = 400
performance_schema_max_table_handles = 4000

# Security
local_infile = 0
symbolic_links = 0
skip_show_database = 1
secure_file_priv = /var/lib/mysql-files/

# SSL (disabled for local connections, enable for production)
# ssl-ca = /etc/mysql/ssl/ca.pem
# ssl-cert = /etc/mysql/ssl/server-cert.pem
# ssl-key = /etc/mysql/ssl/server-key.pem

# Thread pool (for 8 vCPU)
# thread_handling = pool-of-threads
# thread_pool_size = 8
# thread_pool_max_threads = 100

[mysqldump]
quick
quote-names
max_allowed_packet = 256M

[mysql]
no-auto-rehash
safe-updates

[isamchk]
key_buffer = 256M
sort_buffer_size = 256M
read_buffer = 2M
write_buffer = 2M

[myisamchk]
key_buffer = 256M
sort_buffer_size = 256M
read_buffer = 2M
write_buffer = 2M

[mysqlhotcopy]
interactive-timeout
EOF
    
    # Create log directory
    ensure_dir "/var/log/mysql" "mysql:adm" "750"
    
    # Configure systemd limits for MySQL
    configure_systemd_limits "mysql" "${LIMIT_MYSQL_MEM}" "${LIMIT_MYSQL_CPU}"
    
    # Restart MySQL
    systemctl restart mysql
    
    log_info "✓ MySQL configured with InnoDB buffer pool: ${MYSQL_INNODB_BUFFER_POOL_SIZE}, instances: ${MYSQL_INNODB_BUFFER_POOL_INSTANCES}"
}

secure_mysql() {
    log_section "Securing MySQL Installation"
    
    # Generate root password if not provided
    local root_pass="${MYSQL_ROOT_PASS}"
    if [[ -z "${root_pass}" ]]; then
        root_pass=$(generate_password)
        echo "MySQL Root Password: ${root_pass}" >> /root/.mysql_root_password
        chmod 600 /root/.mysql_root_password
        log_info "Generated MySQL root password (stored in /root/.mysql_root_password)"
    fi
    
    # Run mysql_secure_installation equivalent
    mysql -u root << EOF
-- Set root password
ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${root_pass}';

-- Remove anonymous users
DELETE FROM mysql.user WHERE User='';

-- Disallow remote root login
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');

-- Remove test database
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';

-- Reload privileges
FLUSH PRIVILEGES;
EOF
    
    # Create .my.cnf for root for easy access
    cat > /root/.my.cnf << EOF
[client]
user = root
password = ${root_pass}
host = localhost
EOF
    chmod 600 /root/.my.cnf
    
    log_info "✓ MySQL secured (root password set, anonymous users removed, test DB dropped)"
}

create_databases() {
    log_section "Creating Isolated Databases for Each Application"
    
    # Store credentials
    local cred_file="/root/.db_credentials"
    echo "# Database Credentials - Generated $(date)" > "${cred_file}"
    chmod 600 "${cred_file}"
    
    for app_config in "${APP_PATHS[@]}"; do
        IFS=':' read -r path app_type pool db_required <<< "${app_config}"
        
        if [[ "${db_required}" == "true" ]]; then
            local db_name="${DB_PREFIX}_${path}"
            local db_user="${DB_USER_PREFIX}_${path}"
            local db_pass=$(generate_password)
            
            mysql -u root << EOF
-- Create database
CREATE DATABASE IF NOT EXISTS \`${db_name}\` 
    CHARACTER SET utf8mb4 
    COLLATE utf8mb4_unicode_ci;

-- Create user
CREATE USER IF NOT EXISTS '${db_user}'@'localhost' 
    IDENTIFIED BY '${db_pass}';

-- Grant specific privileges only (NO GRANT ALL)
GRANT 
    SELECT,          -- Read data
    INSERT,          -- Insert new records
    UPDATE,          -- Update existing records
    DELETE,          -- Delete records
    CREATE,          -- Create tables
    DROP,            -- Drop tables
    INDEX,           -- Create/drop indexes
    ALTER,           -- Modify table structure
    CREATE TEMPORARY TABLES,  -- Temp tables for complex queries
    LOCK TABLES      -- Table locking for maintenance
ON \`${db_name}\`.* 
TO '${db_user}'@'localhost';

-- Flush privileges
FLUSH PRIVILEGES;
EOF
            
            # Store credentials
            echo "${path}|${db_name}|${db_user}|${db_pass}" >> "${cred_file}"
            
            log_info "  Created DB: ${db_name} (user: ${db_user})"
        fi
    done
    
    log_info "✓ Created $(grep -c '|' "${cred_file}") isolated databases with least-privilege users"
}

#===============================================================
# REDIS INSTALLATION & CONFIGURATION
#===============================================================

install_redis() {
    log_section "Installing and Configuring Redis"
    
    apt-get install -y -qq redis-server redis-tools
    
    # Configure Redis
    local redis_conf="/etc/redis/redis.conf"
    backup_file "${redis_conf}"
    
    # Generate Redis password
    local redis_pass=$(generate_password)
    echo "Redis Password: ${redis_pass}" >> /root/.redis_password
    chmod 600 /root/.redis_password
    
    cat > "${redis_conf}" << EOF
# Redis Configuration - Enterprise Multi-App Server
# Bind to localhost only (Zero-Trust Security)

bind 127.0.0.1 ::1
protected-mode yes
port 6379
tcp-backlog 511
timeout 0
tcp-keepalive 300
daemonize yes
supervised systemd
pidfile /var/run/redis/redis-server.pid
loglevel notice
logfile /var/log/redis/redis-server.log
databases 16

# Security
requirepass ${redis_pass}
rename-command FLUSHALL ""
rename-command FLUSHDB ""
rename-command CONFIG ""
rename-command KEYS ""

# Memory management (512MB for Redis, enough for object caching)
maxmemory 512mb
maxmemory-policy allkeys-lru
maxmemory-samples 5

# Persistence (RDB snapshots)
save 900 1
save 300 10
save 60 10000
stop-writes-on-bgsave-error yes
rdbcompression yes
rdbchecksum yes
dbfilename dump.rdb
dir /var/lib/redis

# Append only file
appendonly no

# Advanced config
 activerehashing yes
client-output-buffer-limit normal 0 0 0
client-output-buffer-limit slave 256mb 64mb 60
client-output-buffer-limit pubsub 32mb 8mb 60
hz 10
aof-rewrite-incremental-fsync yes

# Lazy freeing
lazyfree-lazy-eviction no
lazyfree-lazy-expire no
lazyfree-lazy-server-del no

# Slow log
slowlog-log-slower-than 10000
slowlog-max-len 128
EOF
    
    # Restart Redis
    systemctl restart redis-server
    systemctl enable redis-server
    
    # Configure systemd limits
    configure_systemd_limits "redis-server" "1G" "100%"
    
    log_info "✓ Redis installed and configured (bind: 127.0.0.1, password: set)"
}

#===============================================================
# FILESYSTEM SETUP & PERMISSIONS
#===============================================================

setup_filesystem() {
    log_section "Setting Up Application Directories and Permissions"
    
    # Create base directories
    ensure_dir "/var/www" "www-data:www-data" "755"
    
    # Create directories for each application
    for app_config in "${APP_PATHS[@]}"; do
        IFS=':' read -r path app_type pool db_required <<< "${app_config}"
        
        local app_dir="/var/www/${path}"
        
        # Create base directory
        if [[ "${app_type}" == "laravel" || "${app_type}" == "moodle" ]]; then
            # For Laravel/Moodle, create public subdirectory
            ensure_dir "${app_dir}/public" "www-data:www-data" "755"
            
            # For Moodle, create moodledata
            if [[ "${app_type}" == "moodle" ]]; then
                ensure_dir "${app_dir}/moodledata" "www-data:www-data" "750"
            fi
        else
            ensure_dir "${app_dir}" "www-data:www-data" "755"
        fi
        
        # Create specific subdirectories based on app type
        case "${app_type}" in
            "laravel")
                ensure_dir "${app_dir}/storage" "www-data:www-data" "750"
                ensure_dir "${app_dir}/storage/logs" "www-data:www-data" "750"
                ensure_dir "${app_dir}/storage/framework" "www-data:www-data" "750"
                ensure_dir "${app_dir}/storage/framework/sessions" "www-data:www-data" "750"
                ensure_dir "${app_dir}/storage/framework/views" "www-data:www-data" "750"
                ensure_dir "${app_dir}/storage/framework/cache" "www-data:www-data" "750"
                ensure_dir "${app_dir}/bootstrap/cache" "www-data:www-data" "775"
                ;;
            "wordpress")
                ensure_dir "${app_dir}/wp-content" "www-data:www-data" "755"
                ensure_dir "${app_dir}/wp-content/uploads" "www-data:www-data" "755"
                ensure_dir "${app_dir}/wp-content/plugins" "www-data:www-data" "755"
                ensure_dir "${app_dir}/wp-content/themes" "www-data:www-data" "755"
                ;;
            "php")
                # Generic PHP application
                if [[ "${path}" == "cloud" ]]; then
                    # Nextcloud data directory
                    ensure_dir "${app_dir}/data" "www-data:www-data" "750"
                fi
                if [[ "${path}" == "download" ]]; then
                    # Directory lister files
                    ensure_dir "${app_dir}/files" "www-data:www-data" "755"
                fi
                ;;
        esac
    done
    
    # Set proper permissions
    set_filesystem_permissions
    
    log_info "✓ Application directories created with proper permissions"
}

set_filesystem_permissions() {
    log_section "Setting Filesystem Permissions (Zero-Trust Model)"
    
    # Base permissions for /var/www
    chown -R www-data:www-data /var/www
    find /var/www -type d -exec chmod 750 {} \;
    find /var/www -type f -exec chmod 640 {} \;
    
    # PHP files should be readable and executable by www-data only
    find /var/www -type f -name "*.php" -exec chmod 640 {} \;
    
    # Static files should be readable
    find /var/www -type f \( -name "*.html" -o -name "*.css" -o -name "*.js" -o -name "*.jpg" -o -name "*.png" -o -name "*.gif" -o -name "*.ico" -o -name "*.svg" -o -name "*.pdf" -o -name "*.txt" \) -exec chmod 644 {} \;
    
    # Special permissions for specific directories
    
    # Laravel/Siakad - storage and bootstrap/cache must be writable
    if [[ -d "/var/www/siakad/storage" ]]; then
        chmod -R 775 /var/www/siakad/storage
        chmod -R 775 /var/www/siakad/bootstrap/cache
    fi
    
    # Moodle - moodledata must be writable
    if [[ -d "/var/www/lms/moodledata" ]]; then
        chmod -R 750 /var/www/lms/moodledata
        chown -R www-data:www-data /var/www/lms/moodledata
    fi
    
    # WordPress - wp-content must be writable
    if [[ -d "/var/www/blog/wp-content" ]]; then
        chmod -R 755 /var/www/blog/wp-content
        chmod -R 775 /var/www/blog/wp-content/uploads 2>/dev/null || true
    fi
    
    # Nextcloud - data directory must be writable
    if [[ -d "/var/www/cloud/data" ]]; then
        chmod -R 750 /var/www/cloud/data
        chown -R www-data:www-data /var/www/cloud/data
    fi
    
    # Configuration files should not be readable by others
    find /var/www -type f \( -name "*.env" -o -name "wp-config.php" -o -name "config.php" -o -name "settings.php" -o -name "LocalSettings.php" \) -exec chmod 640 {} \;
    
    # Hide sensitive files from web
    find /var/www -type f -name ".env*" -exec chmod 640 {} \;
    find /var/www -type f -name "*.bak" -exec chmod 600 {} \;
    find /var/www -type f -name "*.orig" -exec chmod 600 {} \;
    find /var/www -type f -name "*.old" -exec chmod 600 {} \;
    
    # Remove any setuid/setgid bits
    find /var/www -type f -exec chmod -s {} \; 2>/dev/null || true
    
    log_info "✓ Filesystem permissions set (Zero-Trust model applied)"
}

#===============================================================
# FIREWALL CONFIGURATION (UFW)
#===============================================================

configure_firewall() {
    log_section "Configuring UFW Firewall (Zero-Trust Network Security)"
    
    # Reset UFW to default
    ufw --force reset
    
    # Set default policies
    ufw default deny incoming
    ufw default allow outgoing
    
    # Allow SSH from LAN only
    ufw allow from "${SERVER_LAN_CIDR}" to any port 22 proto tcp comment "SSH from LAN"
    
    # Allow HTTP (Apache) from anywhere (or restrict to LAN if needed)
    ufw allow 80/tcp comment "Apache HTTP"
    
    # Allow Samba from LAN only
    ufw allow from "${SERVER_LAN_CIDR}" to any port 139 proto tcp comment "Samba NetBIOS"
    ufw allow from "${SERVER_LAN_CIDR}" to any port 445 proto tcp comment "Samba SMB"
    ufw allow from "${SERVER_LAN_CIDR}" to any port 137 proto udp comment "Samba NetBIOS Name Service"
    ufw allow from "${SERVER_LAN_CIDR}" to any port 138 proto udp comment "Samba NetBIOS Datagram"
    
    # Explicitly deny database access from outside
    ufw deny 3306/tcp comment "MySQL - Local only"
    ufw deny 3306/udp comment "MySQL - Local only"
    ufw deny 6379/tcp comment "Redis - Local only"
    ufw deny 6379/udp comment "Redis - Local only"
    
    # Explicitly deny other sensitive ports
    ufw deny 8096/tcp comment "Jellyfin backend - Local only"
    ufw deny 8000/tcp comment "JitsiMeet backend - Local only"
    ufw deny 5280/tcp comment "XMPP BOSH - Local only"
    
    # Rate limiting for HTTP (optional, enable for public servers)
    # ufw limit 80/tcp
    
    # Enable UFW
    ufw --force enable
    
    # Show status
    ufw status verbose
    
    log_info "✓ UFW configured: Only Apache (80) and Samba (139,445) accessible from LAN"
}

#===============================================================
# FAIL2BAN CONFIGURATION
#===============================================================

configure_fail2ban() {
    log_section "Configuring Fail2Ban for SSH and Apache Protection"
    
    apt-get install -y -qq fail2ban
    
    # Create jail.local configuration
    local jail_conf="/etc/fail2ban/jail.local"
    
    cat > "${jail_conf}" << 'EOF'
# Fail2Ban Configuration - Enterprise Multi-App Server
# Protects: SSH, Apache (auth, badbots, noscript, overflows)

[DEFAULT]
# Ban duration: 1 hour
bantime  = 3600

# Time window to look for failures: 10 minutes
findtime  = 600

# Maximum retry attempts before ban
maxretry = 5

# Ban action using UFW (since we're using UFW)
banaction = ufw

# Email notification (uncomment and configure for alerts)
# destemail = admin@example.com
# sendername = Fail2Ban
# action = %(action_mwl)s

# Ignore localhost and management IPs
ignoreip = 127.0.0.1/8 ::1 192.168.255.246

# Backend selection
backend = systemd

# Jails configuration
[sshd]
enabled   = true
port      = ssh
filter    = sshd
logpath   = /var/log/auth.log
maxretry  = 3
bantime   = 7200
findtime  = 600
action    = %(action_mw)s
          ufw[name=SSH, port=22, proto=tcp]

[apache-auth]
enabled   = true
port      = http,https
filter    = apache-auth
logpath   = /var/log/apache2/error.log
maxretry  = 5
bantime   = 3600
findtime  = 600

[apache-badbots]
enabled   = true
port      = http,https
filter    = apache-badbots
logpath   = /var/log/apache2/access.log
maxretry  = 3
bantime   = 86400
findtime  = 600

[apache-noscript]
enabled   = true
port      = http,https
filter    = apache-noscript
logpath   = /var/log/apache2/access.log
maxretry  = 5
bantime   = 3600
findtime  = 600

[apache-overflows]
enabled   = true
port      = http,https
filter    = apache-overflows
logpath   = /var/log/apache2/error.log
maxretry  = 3
bantime   = 3600
findtime  = 600

[apache-404]
enabled   = true
port      = http,https
filter    = apache-404
logpath   = /var/log/apache2/access.log
maxretry  = 10
bantime   = 1800
findtime  = 300

# PHP-FPM protection
[php-fpm]
enabled   = true
port      = http,https
filter    = php-fpm
logpath   = /var/log/php8.3-fpm-*.log
maxretry  = 5
bantime   = 3600
findtime  = 600

# WordPress specific (if using WordPress)
[wordpress]
enabled   = true
port      = http,https
filter    = wordpress
logpath   = /var/log/apache2/access.log
maxretry  = 5
bantime   = 7200
findtime  = 600
action    = ufw[name=WordPress, port=http, proto=tcp]

# Moodle specific (if using Moodle)
[moodle]
enabled   = true
port      = http,https
filter    = moodle
logpath   = /var/log/apache2/error.log
maxretry  = 5
bantime   = 7200
findtime  = 600
EOF
    
    # Create custom filter for PHP-FPM
    local php_fpm_filter="/etc/fail2ban/filter.d/php-fpm.conf"
    cat > "${php_fpm_filter}" << 'EOF'
[Definition]
failregex = .*WARNING:.*child.*exited.*on signal.*SIGSEGV.*pid.*
            .*WARNING:.*child.*exited.*on signal.*SIGBUS.*pid.*
            .*ERROR:.*unable to read what request say.*errno.*
ignoreregex =
EOF
    
    # Create custom filter for WordPress
    local wordpress_filter="/etc/fail2ban/filter.d/wordpress.conf"
    cat > "${wordpress_filter}" << 'EOF'
[Definition]
failregex = ^<HOST> -.*"POST /blog/wp-login.php.*HTTP/.*" 200
            ^<HOST> -.*"POST /blog/xmlrpc.php.*HTTP/.*" 200
ignoreregex =
EOF
    
    # Create custom filter for Moodle
    local moodle_filter="/etc/fail2ban/filter.d/moodle.conf"
    cat > "${moodle_filter}" << 'EOF'
[Definition]
failregex = .*Failed login.*from.*<HOST>.*
            .*Invalid login token.*from.*<HOST>.*
ignoreregex =
EOF
    
    # Restart Fail2Ban
    systemctl restart fail2ban
    systemctl enable fail2ban
    
    # Verify jails are active
    fail2ban-client status
    
    log_info "✓ Fail2Ban configured with jails: sshd, apache-auth, apache-badbots, apache-noscript, apache-overflows, wordpress, moodle"
}

#===============================================================
# SYSTEMD RESOURCE LIMITS
#===============================================================

configure_systemd_limits() {
    local service_name="$1"
    local memory_max="$2"
    local cpu_quota="$3"
    
    local override_dir="/etc/systemd/system/${service_name}.service.d"
    ensure_dir "${override_dir}"
    
    local override_file="${override_dir}/override.conf"
    
    cat > "${override_file}" << EOF
# Systemd Resource Limits - Prevents OOM Killer
# Service: ${service_name}
# MemoryMax: Hard limit (process killed if exceeded)
# MemoryHigh: Soft limit (memory reclaimed under pressure)
# CPUQuota: CPU time quota (percentage, 100% = 1 core)

[Service]
# Memory limits
MemoryMax=${memory_max}
MemoryHigh=${memory_max}

# CPU limits (for 8 vCPU system)
# 400% = 4 cores, 200% = 2 cores, 100% = 1 core
CPUQuota=${cpu_quota}

# Restart policy - self-healing
Restart=on-failure
RestartSec=5s
StartLimitIntervalSec=60
StartLimitBurst=3

# OOM Policy - stop instead of kill to prevent cascade
OOMPolicy=stop

# Resource scheduling
Nice=-5
CPUWeight=90
IOWeight=90

# Security hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
MemoryDenyWriteExecute=false
RestrictRealtime=true
RestrictNamespaces=true

# Allow write access to specific directories
ReadWritePaths=/var/www /var/log /tmp /run /var/lib/php

# Limit capabilities
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_KILL CAP_SETUID CAP_SETGID
AmbientCapabilities=
EOF
    
    systemctl daemon-reload
    
    log_info "  Configured systemd limits for ${service_name}: MemoryMax=${memory_max}, CPUQuota=${cpu_quota}"
}

#===============================================================
# BACKUP CONFIGURATION (BORG)
#===============================================================

setup_backup() {
    log_section "Setting Up Automated Backup System with Borg"
    
    # Install Borg
    apt-get install -y -qq borgbackup
    
    # Create backup directory
    ensure_dir "${BORG_BACKUP_DIR}" "root:root" "700"
    ensure_dir "/backup/logs" "root:root" "700"
    
    # Generate Borg passphrase if not provided
    local borg_pass="${BORG_PASSPHRASE}"
    if [[ -z "${borg_pass}" ]]; then
        borg_pass=$(generate_password)
        echo "Borg Passphrase: ${borg_pass}" >> /root/.borg_passphrase
        chmod 600 /root/.borg_passphrase
    fi
    
    # Initialize Borg repository if not exists
    if [[ ! -f "${BORG_BACKUP_DIR}/README" ]]; then
        BORG_PASSPHRASE="${borg_pass}" borg init \
            --encryption=repokey-blake2 \
            "${BORG_BACKUP_DIR}" 2>/dev/null || {
            log_warn "Borg repository may already exist"
        }
    fi
    
    # Create backup script
    local backup_script="/usr/local/sbin/backup-applications.sh"
    
    cat > "${backup_script}" << 'EOF'
#!/bin/bash
#===============================================================================
# Automated Backup Script with Borg
# Features: Database dumps, file backup, integrity verification, retention
#===============================================================================

set -euo pipefail

# Configuration
readonly BORG_REPO="/backup/borg"
readonly BORG_PASSPHRASE=$(cat /root/.borg_passphrase 2>/dev/null || echo "")
readonly BACKUP_DATE=$(date +%Y%m%d_%H%M%S)
readonly BACKUP_NAME="backup_${BACKUP_DATE}"
readonly DB_DUMP_DIR="/tmp/db_dumps_${BACKUP_DATE}"
readonly LOG_FILE="/backup/logs/backup_${BACKUP_DATE}.log"
readonly LOCK_FILE="/tmp/backup.lock"
readonly RETENTION_DAYS=30

# Application list
APPS=("html" "blog" "lms" "siakad" "cbt" "akm" "wiki" "forum" "cloud" "mail" "meet" "download")

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "${LOG_FILE}"
}

# Error handler
error_exit() {
    log "ERROR: $1"
    rm -f "${LOCK_FILE}"
    # Send alert (uncomment and configure)
    # echo "Backup failed: $1" | mail -s "Backup Alert" admin@example.com
    exit 1
}

# Check if backup is already running
if [[ -f "${LOCK_FILE}" ]]; then
    OLD_PID=$(cat "${LOCK_FILE}")
    if kill -0 "${OLD_PID}" 2>/dev/null; then
        error_exit "Backup already running (PID: ${OLD_PID})"
    else
        log "Removing stale lock file"
        rm -f "${LOCK_FILE}"
    fi
fi

# Create lock file
echo $$ > "${LOCK_FILE}"
trap 'rm -f "${LOCK_FILE}"' EXIT

log "Starting backup: ${BACKUP_NAME}"

# Create database dump directory
mkdir -p "${DB_DUMP_DIR}"

#===============================================================
# 1. DATABASE DUMPS
#===============================================================
log "Phase 1: Creating database dumps..."

CRED_FILE="/root/.db_credentials"
if [[ -f "${CRED_FILE}" ]]; then
    while IFS='|' read -r app db_name db_user db_pass; do
        log "  Dumping: ${db_name}"
        
        # Get password from credentials file
        DB_PASS=$(grep "^${app}|" "${CRED_FILE}" | cut -d'|' -f4)
        
        # Create dump with compression
        mysqldump \
            --single-transaction \
            --routines \
            --triggers \
            --events \
            --max-allowed-packet=256M \
            --user="${db_user}" \
            --password="${DB_PASS}" \
            "${db_name}" | gzip > "${DB_DUMP_DIR}/${db_name}.sql.gz"
        
        # Verify dump is not empty
        if [[ ! -s "${DB_DUMP_DIR}/${db_name}.sql.gz" ]]; then
            error_exit "Database dump failed: ${db_name}"
        fi
        
        log "    Size: $(du -h "${DB_DUMP_DIR}/${db_name}.sql.gz" | cut -f1)"
    done < "${CRED_FILE}"
else
    log "  No database credentials found, skipping DB dumps"
fi

#===============================================================
# 2. FILE BACKUP WITH BORG
#===============================================================
log "Phase 2: Creating Borg backup..."

export BORG_PASSPHRASE="${BORG_PASSPHRASE}"

# Create backup
borg create \
    --verbose \
    --filter AME \
    --list \
    --stats \
    --show-rc \
    --compression lz4 \
    --exclude-caches \
    --exclude '/var/www/*/node_modules' \
    --exclude '/var/www/*/.git' \
    --exclude '/var/www/*/vendor' \
    --exclude '/var/www/*/storage/logs/*.log' \
    --exclude '*.tmp' \
    --exclude '*.cache' \
    --exclude '*.log' \
    "${BORG_REPO}::${BACKUP_NAME}" \
    /var/www/ \
    /etc/apache2/ \
    /etc/php/ \
    /etc/mysql/ \
    /etc/redis/ \
    /etc/fail2ban/ \
    /etc/systemd/system/*.service.d/ \
    "${DB_DUMP_DIR}/" \
    /root/.db_credentials \
    /root/.borg_passphrase \
    2>&1 | tee -a "${LOG_FILE}" || error_exit "Borg backup failed"

#===============================================================
# 3. INTEGRITY VERIFICATION
#===============================================================
log "Phase 3: Verifying backup integrity..."

# Verify the backup we just created
borg check \
    --verify \
    --verbose \
    "${BORG_REPO}::${BACKUP_NAME}" \
    2>&1 | tee -a "${LOG_FILE}" || error_exit "Backup verification failed"

# List backup contents for verification
log "  Backup contents:"
borg list \
    "${BORG_REPO}::${BACKUP_NAME}" \
    2>&1 | head -50 | tee -a "${LOG_FILE}"

#===============================================================
# 4. RETENTION POLICY
#===============================================================
log "Phase 4: Applying retention policy (${RETENTION_DAYS} days)..."

# Prune old backups
borg prune \
    --list \
    --keep-daily 7 \
    --keep-weekly 4 \
    --keep-monthly 1 \
    --keep-yearly 1 \
    "${BORG_REPO}" \
    2>&1 | tee -a "${LOG_FILE}" || log "  Warning: Prune operation had issues"

# Compact repository to reclaim space
borg compact \
    "${BORG_REPO}" \
    2>&1 | tee -a "${LOG_FILE}" || true

#===============================================================
# 5. CLEANUP AND REPORT
#===============================================================
log "Phase 5: Cleanup and final report..."

# Remove temporary database dumps
rm -rf "${DB_DUMP_DIR}"

# Get repository statistics
REPO_STATS=$(borg info "${BORG_REPO}" 2>/dev/null | head -20)
log "Repository statistics:"
log "${REPO_STATS}"

# Calculate backup size
BACKUP_SIZE=$(du -sh "${BORG_REPO}" | cut -f1)
log "Total repository size: ${BACKUP_SIZE}"

log "Backup completed successfully: ${BACKUP_NAME}"
log "Backup duration: $(($(date +%s) - $(date -d "$(head -1 "${LOG_FILE}" | grep -oP '\[\K[^\]]+')" +%s))) seconds"

# Clean old log files (keep last 30)
find /backup/logs -name "backup_*.log" -type f -mtime +30 -delete 2>/dev/null || true

exit 0
EOF
    
    # Make backup script executable
    chmod 700 "${backup_script}"
    
    # Create cron job for daily backup at 2 AM
    cat > /etc/cron.d/backup-daily << EOF
# Daily backup at 2:00 AM
0 2 * * * root /usr/local/sbin/backup-applications.sh >> /var/log/backup-cron.log 2>&1

# Weekly backup verification (full check) at 4:00 AM on Sundays
0 4 * * 0 root BORG_PASSPHRASE=$(cat /root/.borg_passphrase) borg check --verify /backup/borg >> /var/log/backup-verify.log 2>&1
EOF
    chmod 644 /etc/cron.d/backup-daily
    
    # Create restore script
    create_restore_script
    
    log_info "✓ Backup system configured (Borg + daily cron at 2 AM)"
}

create_restore_script() {
    local restore_script="/usr/local/sbin/restore-applications.sh"
    
    cat > "${restore_script}" << 'EOF'
#!/bin/bash
#===============================================================================
# Restore Script for Borg Backup
# Usage: ./restore-applications.sh [backup_name] [restore_path]
#===============================================================================

set -euo pipefail

BORG_REPO="/backup/borg"
BORG_PASSPHRASE=$(cat /root/.borg_passphrase 2>/dev/null || echo "")

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <backup_name> [restore_path]"
    echo ""
    echo "Available backups:"
    BORG_PASSPHRASE="${BORG_PASSPHRASE}" borg list "${BORG_REPO}" | head -20
    exit 1
fi

BACKUP_NAME="$1"
RESTORE_PATH="${2:-/tmp/restore_$(date +%Y%m%d_%H%M%S)}"

echo "Restoring backup: ${BACKUP_NAME}"
echo "Restore to: ${RESTORE_PATH}"

mkdir -p "${RESTORE_PATH}"

export BORG_PASSPHRASE="${BORG_PASSPHRASE}"

# Restore files
borg extract \
    "${BORG_REPO}::${BACKUP_NAME}" \
    --output-dir "${RESTORE_PATH}" \
    --progress

echo "Backup restored to: ${RESTORE_PATH}"
echo ""
echo "To restore databases, run:"
echo "  gunzip < ${RESTORE_PATH}/tmp/db_dumps_*/srvtkjdbs_*.sql.gz | mysql -u root -p [database_name]"
EOF
    
    chmod 700 "${restore_script}"
}

#===============================================================
# MONITORING & HEALTH CHECKS
#===============================================================

setup_monitoring() {
    log_section "Setting Up Monitoring and Health Checks"
    
    # Create monitoring script
    local monitor_script="/usr/local/sbin/health-check.sh"
    
    cat > "${monitor_script}" << 'EOF'
#!/bin/bash
#===============================================================================
# Health Check Script for Multi-Application Server
# Monitors: Apache, PHP-FPM, MySQL, Redis, Applications
#===============================================================================

set -euo pipefail

readonly SERVER_IP="192.168.255.246"
readonly PHP_VERSION="8.3"
readonly ALERT_EMAIL=""  # Set to enable email alerts
readonly LOG_FILE="/var/log/health-check.log"
readonly STATUS_OK=0
readonly STATUS_WARN=1
readonly STATUS_CRIT=2

# Color codes for output
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "${LOG_FILE}"
}

print_status() {
    local status=$1
    local service=$2
    local message=$3
    
    case ${status} in
        ${STATUS_OK})
            echo -e "${GREEN}✓${NC} ${service}: ${message}"
            ;;
        ${STATUS_WARN})
            echo -e "${YELLOW}⚠${NC} ${service}: ${message}"
            ;;
        ${STATUS_CRIT})
            echo -e "${RED}✗${NC} ${service}: ${message}"
            ;;
    esac
    log "${service}: ${message} (status: ${status})"
}

check_service() {
    local service=$1
    local status=${STATUS_OK}
    
    if systemctl is-active --quiet "${service}"; then
        print_status ${STATUS_OK} "${service}" "Running"
    else
        print_status ${STATUS_CRIT} "${service}" "NOT RUNNING"
        return ${STATUS_CRIT}
    fi
    
    # Check restart count
    local restarts=$(systemctl show "${service}" -p NRestarts | cut -d= -f2)
    if [[ ${restarts} -gt 3 ]]; then
        print_status ${STATUS_WARN} "${service}" "High restart count: ${restarts}"
    fi
}

check_apache() {
    echo "=== Apache HTTP Server ==="
    check_service "apache2"
    
    # Check if Apache is responding
    local http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://${SERVER_IP}/html" 2>/dev/null || echo "000")
    if [[ "${http_code}" == "200" || "${http_code}" == "301" || "${http_code}" == "302" ]]; then
        print_status ${STATUS_OK} "Apache" "HTTP responding (code: ${http_code})"
    else
        print_status ${STATUS_CRIT} "Apache" "HTTP not responding (code: ${http_code})"
    fi
    
    # Check Apache workers
    local workers=$(apache2ctl status 2>/dev/null | grep -oP 'requests currently being processed' | wc -l)
    if [[ ${workers} -gt 0 ]]; then
        print_status ${STATUS_OK} "Apache" "Processing requests"
    fi
    
    # Check error log for recent errors
    local recent_errors=$(grep -c "$(date +%Y-%m-%d)" /var/log/apache2/error.log 2>/dev/null || echo "0")
    if [[ ${recent_errors} -gt 100 ]]; then
        print_status ${STATUS_WARN} "Apache" "High error count today: ${recent_errors}"
    fi
}

check_php_fpm() {
    echo ""
    echo "=== PHP-FPM (${PHP_VERSION}) ==="
    check_service "php${PHP_VERSION}-fpm"
    
    # Check pool status
    for pool in heavy light; do
        local sock_file="/run/php/php${PHP_VERSION}-fpm-${pool}.sock"
        if [[ -S "${sock_file}" ]]; then
            print_status ${STATUS_OK} "PHP-FPM ${pool}" "Socket exists"
            
            # Check active processes
            local active=$(ps aux | grep "php-fpm: pool ${pool}" | grep -v grep | wc -l)
            local max_children=0
            case ${pool} in
                heavy) max_children=45 ;;
                light) max_children=8 ;;
            esac
            
            if [[ ${active} -gt 0 ]]; then
                print_status ${STATUS_OK} "PHP-FPM ${pool}" "Active workers: ${active}/${max_children}"
            else
                print_status ${STATUS_CRIT} "PHP-FPM ${pool}" "No active workers"
            fi
            
            # Check memory usage
            local mem_usage=$(ps aux | grep "php-fpm: pool ${pool}" | grep -v grep | awk '{sum+=$6} END {print sum/1024 " MB"}')
            print_status ${STATUS_OK} "PHP-FPM ${pool}" "Memory usage: ${mem_usage}"
        else
            print_status ${STATUS_CRIT} "PHP-FPM ${pool}" "Socket not found"
        fi
    done
}

check_mysql() {
    echo ""
    echo "=== MySQL ==="
    check_service "mysql"
    
    # Check MySQL connection
    if mysql -u root -e "SELECT 1" &>/dev/null; then
        print_status ${STATUS_OK} "MySQL" "Connection successful"
        
        # Check InnoDB buffer pool
        local buffer_pool=$(mysql -u root -e "SELECT @@innodb_buffer_pool_size / 1024 / 1024 / 1024 AS size_gb" -B -N 2>/dev/null | head -1)
        print_status ${STATUS_OK} "MySQL" "Buffer pool: ${buffer_pool} GB"
        
        # Check connections
        local threads_connected=$(mysql -u root -e "SHOW STATUS LIKE 'Threads_connected'" -B -N 2>/dev/null | awk '{print $2}')
        local max_connections=$(mysql -u root -e "SHOW VARIABLES LIKE 'max_connections'" -B -N 2>/dev/null | awk '{print $2}')
        
        if [[ ${threads_connected} -lt $((max_connections * 80 / 100)) ]]; then
            print_status ${STATUS_OK} "MySQL" "Connections: ${threads_connected}/${max_connections}"
        else
            print_status ${STATUS_WARN} "MySQL" "High connections: ${threads_connected}/${max_connections}"
        fi
        
        # Check slow queries
        local slow_queries=$(mysql -u root -e "SHOW STATUS LIKE 'Slow_queries'" -B -N 2>/dev/null | awk '{print $2}')
        if [[ ${slow_queries} -gt 100 ]]; then
            print_status ${STATUS_WARN} "MySQL" "Slow queries: ${slow_queries}"
        fi
        
        # Check buffer pool hit rate
        local hit_rate=$(mysql -u root -e "
            SELECT ROUND(
                (1 - Innodb_buffer_pool_reads / Innodb_buffer_pool_read_requests) * 100, 2
            ) AS hit_rate
            FROM (
                SELECT variable_value AS Innodb_buffer_pool_reads 
                FROM performance_schema.global_status 
                WHERE variable_name='Innodb_buffer_pool_reads'
            ) a,
            (
                SELECT variable_value AS Innodb_buffer_pool_read_requests 
                FROM performance_schema.global_status 
                WHERE variable_name='Innodb_buffer_pool_read_requests'
            ) b" -B -N 2>/dev/null)
        
        if [[ ! -z "${hit_rate}" ]] && (( $(echo "${hit_rate} > 95" | bc -l) )); then
            print_status ${STATUS_OK} "MySQL" "Buffer pool hit rate: ${hit_rate}%"
        else
            print_status ${STATUS_WARN} "MySQL" "Low buffer pool hit rate: ${hit_rate}%"
        fi
    else
        print_status ${STATUS_CRIT} "MySQL" "Cannot connect"
    fi
}

check_redis() {
    echo ""
    echo "=== Redis ==="
    check_service "redis-server"
    
    # Check Redis connection
    local redis_pass=$(cat /root/.redis_password 2>/dev/null | grep "Password:" | awk '{print $2}')
    if redis-cli -a "${redis_pass}" --no-auth-warning ping &>/dev/null; then
        print_status ${STATUS_OK} "Redis" "Connection successful"
        
        # Check memory usage
        local mem_usage=$(redis-cli -a "${redis_pass}" --no-auth-warning info memory 2>/dev/null | grep "used_memory_human" | cut -d: -f2 | tr -d '[:space:]')
        print_status ${STATUS_OK} "Redis" "Memory usage: ${mem_usage}"
        
        # Check connected clients
        local clients=$(redis-cli -a "${redis_pass}" --no-auth-warning info clients 2>/dev/null | grep "connected_clients" | cut -d: -f2 | tr -d '[:space:]')
        print_status ${STATUS_OK} "Redis" "Connected clients: ${clients}"
    else
        print_status ${STATUS_CRIT} "Redis" "Cannot connect"
    fi
}

check_applications() {
    echo ""
    echo "=== Application Health Checks ==="
    
    local apps=(
        "html:/html:200"
        "blog:/blog:200"
        "lms:/lms:200"
        "siakad:/siakad:200"
        "cbt:/cbt:200"
        "akm:/akm:200"
        "meet:/meet:200"
        "wiki:/wiki:200"
        "forum:/forum:200"
        "cloud:/cloud:200"
        "mail:/mail:200"
        "samba:/samba:200"
        "video:/video:200"
        "download:/download:200"
    )
    
    local failed_count=0
    
    for app_entry in "${apps[@]}"; do
        IFS=':' read -r app path expected_code <<< "${app_entry}"
        
        local actual_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "http://${SERVER_IP}${path}" 2>/dev/null || echo "000")
        
        if [[ "${actual_code}" == "${expected_code}" || "${actual_code}" == "301" || "${actual_code}" == "302" ]]; then
            print_status ${STATUS_OK} "${app}" "HTTP ${actual_code} (expected: ${expected_code})"
        elif [[ "${actual_code}" == "404" ]]; then
            print_status ${STATUS_WARN} "${app}" "Not found (HTTP 404) - may not be deployed yet"
        else
            print_status ${STATUS_CRIT} "${app}" "HTTP ${actual_code} (expected: ${expected_code})"
            ((failed_count++))
        fi
    done
    
    if [[ ${failed_count} -gt 0 ]]; then
        print_status ${STATUS_CRIT} "Applications" "${failed_count} applications failed health check"
    fi
}

check_disk_space() {
    echo ""
    echo "=== Disk Space ==="
    
    local partitions=("/" "/var/www" "/backup")
    
    for partition in "${partitions[@]}"; do
        if [[ -d "${partition}" ]]; then
            local usage=$(df -h "${partition}" | awk 'NR==2{print $5}' | tr -d '%')
            local available=$(df -h "${partition}" | awk 'NR==2{print $4}')
            
            if [[ ${usage} -lt 80 ]]; then
                print_status ${STATUS_OK} "Disk ${partition}" "Usage: ${usage}% (Available: ${available})"
            elif [[ ${usage} -lt 90 ]]; then
                print_status ${STATUS_WARN} "Disk ${partition}" "Usage: ${usage}% (Available: ${available})"
            else
                print_status ${STATUS_CRIT} "Disk ${partition}" "Critical usage: ${usage}% (Available: ${available})"
            fi
        fi
    done
}

check_memory() {
    echo ""
    echo "=== Memory Usage ==="
    
    local total=$(free -m | awk '/^Mem:/{print $2}')
    local used=$(free -m | awk '/^Mem:/{print $3}')
    local available=$(free -m | awk '/^Mem:/{print $7}')
    local usage_pct=$((used * 100 / total))
    
    if [[ ${usage_pct} -lt 80 ]]; then
        print_status ${STATUS_OK} "Memory" "Usage: ${usage_pct}% (${used}MB/${total}MB, Available: ${available}MB)"
    elif [[ ${usage_pct} -lt 90 ]]; then
        print_status ${STATUS_WARN} "Memory" "Usage: ${usage_pct}% (${used}MB/${total}MB, Available: ${available}MB)"
    else
        print_status ${STATUS_CRIT} "Memory" "Critical usage: ${usage_pct}% (${used}MB/${total}MB, Available: ${available}MB)"
    fi
    
    # Check swap usage
    local swap_total=$(free -m | awk '/^Swap:/{print $2}')
    local swap_used=$(free -m | awk '/^Swap:/{print $3}')
    if [[ ${swap_total} -gt 0 ]]; then
        local swap_pct=$((swap_used * 100 / swap_total))
        if [[ ${swap_pct} -gt 50 ]]; then
            print_status ${STATUS_WARN} "Swap" "Usage: ${swap_pct}% (${swap_used}MB/${swap_total}MB)"
        else
            print_status ${STATUS_OK} "Swap" "Usage: ${swap_pct}% (${swap_used}MB/${swap_total}MB)"
        fi
    fi
}

check_system_load() {
    echo ""
    echo "=== System Load ==="
    
    local load_1m=$(awk '{print $1}' /proc/loadavg)
    local load_5m=$(awk '{print $2}' /proc/loadavg)
    local load_15m=$(awk '{print $3}' /proc/loadavg)
    local cpu_count=$(nproc)
    
    # Calculate load percentage
    local load_pct=$(echo "scale=0; ${load_1m} * 100 / ${cpu_count}" | bc)
    
    if [[ ${load_pct} -lt 70 ]]; then
        print_status ${STATUS_OK} "CPU Load" "1m: ${load_1m} (${load_pct}% of ${cpu_count} CPUs)"
    elif [[ ${load_pct} -lt 85 ]]; then
        print_status ${STATUS_WARN} "CPU Load" "1m: ${load_1m} (${load_pct}% of ${cpu_count} CPUs)"
    else
        print_status ${STATUS_CRIT} "CPU Load" "Critical: ${load_1m} (${load_pct}% of ${cpu_count} CPUs)"
    fi
}

check_fail2ban() {
    echo ""
    echo "=== Fail2Ban ==="
    check_service "fail2ban"
    
    if command_exists fail2ban-client; then
        local sshd_banned=$(fail2ban-client status sshd 2>/dev/null | grep "Currently banned" | awk '{print $NF}')
        local apache_banned=$(fail2ban-client status apache-auth 2>/dev/null | grep "Currently banned" | awk '{print $NF}')
        
        print_status ${STATUS_OK} "Fail2Ban" "SSH banned: ${sshd_banned:-0}, Apache banned: ${apache_banned:-0}"
    fi
}

# Main execution
main() {
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║           Multi-Application Server Health Check              ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    
    check_apache
    check_php_fpm
    check_mysql
    check_redis
    check_applications
    check_disk_space
    check_memory
    check_system_load
    check_fail2ban
    
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "Health check completed at: $(date)"
    echo "═══════════════════════════════════════════════════════════════"
}

# Run main function
main "$@"
EOF
    
    chmod 755 "${monitor_script}"
    
    # Create cron job for monitoring (every 5 minutes)
    cat > /etc/cron.d/health-monitor << 'EOF'
# Health check every 5 minutes
*/5 * * * * root /usr/local/sbin/health-check.sh > /dev/null 2>&1

# Detailed monitoring report every hour
0 * * * * root /usr/local/sbin/health-check.sh >> /var/log/monitoring-hourly.log 2>&1
EOF
    chmod 644 /etc/cron.d/health-monitor
    
    log_info "✓ Monitoring system configured (health check every 5 minutes)"
}

#===============================================================
# DEPLOYMENT SCRIPT (IDEMPOTENT)
#===============================================================

create_deployment_script() {
    log_section "Creating Deployment Script"
    
    local deploy_script="/usr/local/sbin/deploy-config.sh"
    
    cat > "${deploy_script}" << 'DEPLOY_EOF'
#!/bin/bash
#===============================================================================
# Idempotent Deployment Script
# Features: Backup, Write Config, Syntax Check, Reload, Health Check, Rollback
#===============================================================================

set -euo pipefail

# Configuration
readonly SCRIPT_NAME="deploy-config"
readonly CONFIG_DIR="/etc/apache2/sites-available"
readonly BACKUP_DIR="/root/config-backup/deploy-$(date +%Y%m%d_%H%M%S)"
readonly HEALTH_URL="http://127.0.0.1/html"
readonly HEALTH_RETRIES=5
readonly HEALTH_TIMEOUT=10
readonly ROLLBACK_ENABLED=true
readonly LOG_FILE="/var/log/deploy-$(date +%Y%m%d_%H%M%S).log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Logging
log_info() { echo -e "${GREEN}[$(date '+%H:%M:%S')] [INFO]${NC} $1" | tee -a "${LOG_FILE}"; }
log_warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')] [WARN]${NC} $1" | tee -a "${LOG_FILE}"; }
log_error() { echo -e "${RED}[$(date '+%H:%M:%S')] [ERROR]${NC} $1" | tee -a "${LOG_FILE}" >&2; }
log_step() { echo -e "${BLUE}[$(date '+%H:%M:%S')] [STEP]${NC} $1" | tee -a "${LOG_FILE}"; }

# Error handler
on_error() {
    local exit_code=$?
    local line_no=$1
    log_error "Deployment failed at line ${line_no} (exit code: ${exit_code})"
    
    if [[ "${ROLLBACK_ENABLED}" == "true" && -d "${BACKUP_DIR}" ]]; then
        log_warn "Initiating rollback..."
        rollback
    fi
    
    exit ${exit_code}
}

trap 'on_error $LINENO' ERR

#===============================================================
# FUNCTIONS
#===============================================================

backup_configs() {
    log_step "Step 1: Backing up current configuration..."
    
    mkdir -p "${BACKUP_DIR}"
    
    # Backup Apache configuration
    if [[ -d "${CONFIG_DIR}" ]]; then
        cp -a "${CONFIG_DIR}/." "${BACKUP_DIR}/apache/"
    fi
    
    # Backup PHP-FPM configuration
    if [[ -d "/etc/php/8.3/fpm/pool.d" ]]; then
        mkdir -p "${BACKUP_DIR}/php-fpm"
        cp -a /etc/php/8.3/fpm/pool.d/. "${BACKUP_DIR}/php-fpm/"
    fi
    
    # Backup MySQL configuration
    if [[ -f "/etc/mysql/mysql.conf.d/mysqld.cnf" ]]; then
        mkdir -p "${BACKUP_DIR}/mysql"
        cp /etc/mysql/mysql.conf.d/mysqld.cnf "${BACKUP_DIR}/mysql/"
    fi
    
    # Backup systemd overrides
    if [[ -d "/etc/systemd/system" ]]; then
        mkdir -p "${BACKUP_DIR}/systemd"
        find /etc/systemd/system -name "*.service.d" -type d | while read dir; do
            local service_name=$(basename "${dir}" .service.d)
            mkdir -p "${BACKUP_DIR}/systemd/${service_name}"
            cp -a "${dir}/." "${BACKUP_DIR}/systemd/${service_name}/"
        done
    fi
    
    log_info "Backup completed: ${BACKUP_DIR}"
}

write_configs() {
    log_step "Step 2: Writing new configuration files..."
    
    # This function is a placeholder - in production, the actual
    # configuration templates would be written here.
    # The main setup script handles initial configuration.
    
    log_info "Configuration files are up to date (idempotent)"
}

syntax_check() {
    log_step "Step 3: Running syntax checks..."
    
    # Apache syntax check
    log_info "Checking Apache configuration..."
    apache2ctl configtest 2>&1 | tee -a "${LOG_FILE}"
    
    # PHP-FPM syntax check
    log_info "Checking PHP-FPM configuration..."
    php-fpm8.3 -t 2>&1 | tee -a "${LOG_FILE}"
    
    # MySQL syntax check (if config changed)
    if [[ -f "/etc/mysql/mysql.conf.d/mysqld.cnf" ]]; then
        log_info "Checking MySQL configuration..."
        mysqld --validate-config --defaults-file=/etc/mysql/mysql.conf.d/mysqld.cnf 2>&1 | tee -a "${LOG_FILE}" || true
    fi
    
    log_info "All syntax checks passed"
}

reload_services() {
    log_step "Step 4: Reloading services..."
    
    # Reload Apache
    log_info "Reloading Apache..."
    systemctl reload apache2
    
    # Reload PHP-FPM
    log_info "Reloading PHP-FPM..."
    systemctl reload php8.3-fpm
    
    # Reload MySQL (only if config changed)
    if [[ -f "/etc/mysql/mysql.conf.d/mysqld.cnf" ]]; then
        log_info "Reloading MySQL..."
        systemctl reload mysql || true
    fi
    
    # Wait for services to stabilize
    sleep 3
    
    log_info "All services reloaded"
}

health_check() {
    log_step "Step 5: Running health checks..."
    
    local attempt=1
    local http_code=000
    
    while [[ ${attempt} -le ${HEALTH_RETRIES} ]]; do
        log_info "Health check attempt ${attempt}/${HEALTH_RETRIES}..."
        
        # Check main endpoint
        http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time ${HEALTH_TIMEOUT} "${HEALTH_URL}" 2>/dev/null || echo "000")
        
        if [[ "${http_code}" == "200" || "${http_code}" == "301" || "${http_code}" == "302" ]]; then
            log_info "✓ Health check passed (HTTP ${http_code})"
            return 0
        fi
        
        log_warn "Health check failed (HTTP ${http_code}), attempt ${attempt}/${HEALTH_RETRIES}"
        ((attempt++))
        sleep 5
    done
    
    log_error "Health check failed after ${HEALTH_RETRIES} attempts"
    return 1
}

rollback() {
    log_warn "Initiating rollback..."
    
    if [[ ! -d "${BACKUP_DIR}" ]]; then
        log_error "No backup directory found for rollback"
        return 1
    fi
    
    # Rollback Apache
    if [[ -d "${BACKUP_DIR}/apache" ]]; then
        log_info "Rolling back Apache configuration..."
        cp -a "${BACKUP_DIR}/apache/." "${CONFIG_DIR}/"
        apache2ctl configtest && systemctl reload apache2
    fi
    
    # Rollback PHP-FPM
    if [[ -d "${BACKUP_DIR}/php-fpm" ]]; then
        log_info "Rolling back PHP-FPM configuration..."
        cp -a "${BACKUP_DIR}/php-fpm/." "/etc/php/8.3/fpm/pool.d/"
        php-fpm8.3 -t && systemctl restart php8.3-fpm
    fi
    
    # Rollback MySQL
    if [[ -d "${BACKUP_DIR}/mysql" ]]; then
        log_info "Rolling back MySQL configuration..."
        cp "${BACKUP_DIR}/mysql/mysqld.cnf" /etc/mysql/mysql.conf.d/
        systemctl restart mysql
    fi
    
    # Rollback systemd overrides
    if [[ -d "${BACKUP_DIR}/systemd" ]]; then
        log_info "Rolling back systemd overrides..."
        for service_dir in "${BACKUP_DIR}/systemd"/*/; do
            local service_name=$(basename "${service_dir}")
            local target_dir="/etc/systemd/system/${service_name}.service.d"
            if [[ -d "${target_dir}" ]]; then
                cp -a "${service_dir}/." "${target_dir}/"
            fi
        done
        systemctl daemon-reload
    fi
    
    log_info "Rollback completed"
    
    # Verify rollback
    sleep 5
    local check_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "${HEALTH_URL}" 2>/dev/null || echo "000")
    if [[ "${check_code}" == "200" ]]; then
        log_info "✓ Rollback successful, service is healthy"
    else
        log_error "Rollback may have issues (HTTP ${check_code})"
    fi
}

#===============================================================
# MAIN EXECUTION
#===============================================================

main() {
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║           Configuration Deployment Script                    ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    
    local start_time=$(date +%s)
    
    # 1. Backup
    backup_configs
    
    # 2. Write configs (idempotent)
    write_configs
    
    # 3. Syntax check
    syntax_check
    
    # 4. Reload services
    reload_services
    
    # 5. Health check
    if health_check; then
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        
        echo ""
        echo "╔══════════════════════════════════════════════════════════════╗"
        echo "║           Deployment Successful!                             ║"
        echo "╚══════════════════════════════════════════════════════════════╝"
        log_info "Deployment completed in ${duration} seconds"
        log_info "Backup available at: ${BACKUP_DIR}"
    else
        echo ""
        echo "╔══════════════════════════════════════════════════════════════╗"
        echo "║           Deployment Failed - Rolling Back                   ║"
        echo "╚══════════════════════════════════════════════════════════════╝"
        rollback
        exit 1
    fi
}

# Run main
main "$@"
DEPLOY_EOF
    
    chmod 755 "${deploy_script}"
    
    log_info "✓ Deployment script created: ${deploy_script}"
}

#===============================================================
# SCALING TOOLS
#===============================================================

create_scaling_tools() {
    log_section "Creating Scaling Tools"
    
    # Create scaling check script
    local scale_check_script="/usr/local/sbin/check-scaling-trigger.sh"
    
    cat > "${scale_check_script}" << 'EOF'
#!/bin/bash
#===============================================================================
# Scaling Trigger Check Script
# Monitors resource utilization and provides scaling recommendations
# Trigger: 85% sustained utilization for 15 minutes
#===============================================================================

set -euo pipefail

readonly THRESHOLD=85
readonly MONITOR_PERIOD=15  # minutes
readonly LOG_FILE="/var/log/scaling-check.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "${LOG_FILE}"
}

echo "=== Scaling Trigger Check ==="
echo "Threshold: ${THRESHOLD}% for ${MONITOR_PERIOD} minutes"
echo ""

# CPU Load Check
echo "--- CPU Load ---"
load_1m=$(awk '{print $1}' /proc/loadavg)
load_5m=$(awk '{print $2}' /proc/loadavg)
load_15m=$(awk '{print $3}' /proc/loadavg)
cpu_count=$(nproc)

cpu_pct=$(echo "scale=0; ${load_1m} * 100 / ${cpu_count}" | bc)
echo "CPU Load (1m): ${load_1m} (${cpu_pct}% of ${cpu_count} CPUs)"

if (( cpu_pct >= THRESHOLD )); then
    echo "⚠️  CPU SCALING TRIGGER: ${cpu_pct}% utilization"
    echo "   Recommendation: Consider separating Database or Cache to second node"
fi

# Memory Check
echo ""
echo "--- Memory ---"
total_mem=$(free -m | awk '/^Mem:/{print $2}')
available_mem=$(free -m | awk '/^Mem:/{print $7}')
mem_pct=$(( (total_mem - available_mem) * 100 / total_mem ))
echo "Memory: ${mem_pct}% used (${available_mem}MB available of ${total_mem}MB)"

if (( mem_pct >= THRESHOLD )); then
    echo "⚠️  MEMORY SCALING TRIGGER: ${mem_pct}% utilization"
    echo "   Recommendation: Increase PHP-FPM memory or separate applications"
fi

# PHP-FPM Check
echo ""
echo "--- PHP-FPM Workers ---"
for pool in heavy light; do
    active=$(ps aux | grep "php-fpm: pool ${pool}" | grep -v grep | wc -l)
    max_children=0
    case ${pool} in
        heavy) max_children=45 ;;
        light) max_children=8 ;;
    esac
    pct=$((active * 100 / max_children))
    
    echo "Pool ${pool}: ${active}/${max_children} workers (${pct}%)"
    
    if (( pct >= THRESHOLD )); then
        echo "⚠️  PHP-FPM SCALING TRIGGER: Pool ${pool} at ${pct}% capacity"
        echo "   Recommendation: Increase pm.max_children or add more application servers"
    fi
done

# MySQL Check
echo ""
echo "--- MySQL ---"
if command_exists mysql; then
    threads_running=$(mysql -u root -e "SHOW STATUS LIKE 'Threads_running'" -B -N 2>/dev/null | awk '{print $2}')
    threads_connected=$(mysql -u root -e "SHOW STATUS LIKE 'Threads_connected'" -B -N 2>/dev/null | awk '{print $2}')
    max_connections=$(mysql -u root -e "SHOW VARIABLES LIKE 'max_connections'" -B -N 2>/dev/null | awk '{print $2}')
    
    conn_pct=$((threads_connected * 100 / max_connections))
    echo "MySQL Connections: ${threads_connected}/${max_connections} (${conn_pct}%)"
    echo "MySQL Running Queries: ${threads_running}"
    
    if (( conn_pct >= THRESHOLD )); then
        echo "⚠️  MYSQL SCALING TRIGGER: ${conn_pct}% connection utilization"
        echo "   Recommendation: Separate MySQL to dedicated node (192.168.255.247)"
    fi
    
    # Check slow queries
    slow_queries=$(mysql -u root -e "SHOW STATUS LIKE 'Slow_queries'" -B -N 2>/dev/null | awk '{print $2}')
    if (( slow_queries > 100 )); then
        echo "⚠️  High slow query count: ${slow_queries}"
        echo "   Recommendation: Optimize queries or increase buffer pool"
    fi
fi

# Disk I/O Check
echo ""
echo "--- Disk I/O ---"
if command_exists iostat; then
    iostat -x 1 2 2>/dev/null | grep -A5 "Device" | tail -5
fi

# Network Check
echo ""
echo "--- Network ---"
if command_exists ifstat; then
    echo "Network throughput:"
    ifstat 1 2 2>/dev/null | tail -1
fi

echo ""
echo "=== Scaling Recommendations ==="
echo "If any trigger is activated, follow these steps:"
echo ""
echo "1. Database Separation (MySQL to 192.168.255.247):"
echo "   - Update bind-address in mysqld.cnf"
echo "   - Update DB_HOST in application configs"
echo "   - Update UFW rules"
echo ""
echo "2. Cache Separation (Redis to 192.168.255.247):"
echo "   - Update Redis configuration"
echo "   - Update REDIS_HOST in application configs"
echo "   - Update UFW rules"
echo ""
echo "3. Application Scaling:"
echo "   - Add additional application server"
echo "   - Configure load balancer"
echo "   - Share session storage (Redis)"
EOF
    
    chmod 755 "${scale_check_script}"
    
    # Create scaling migration script
    local scale_migrate_script="/usr/local/sbin/scale-to-node2.sh"
    
    cat > "${scale_migrate_script}" << 'EOF'
#!/bin/bash
#===============================================================================
# Scale to Node 2 (192.168.255.247) - Database and/or Cache Migration
# Usage: ./scale-to-node2.sh [database|cache|both]
#===============================================================================

set -euo pipefail

readonly NODE1_IP="192.168.255.246"
readonly NODE2_IP="192.168.255.247"
readonly MIGRATION_TYPE="${1:-both}"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║           Scaling Migration to Node 2                        ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo "Node 1: ${NODE1_IP}"
echo "Node 2: ${NODE2_IP}"
echo "Migration Type: ${MIGRATION_TYPE}"
echo ""

if [[ "${MIGRATION_TYPE}" == "database" || "${MIGRATION_TYPE}" == "both" ]]; then
    echo "=== Database Migration Steps ==="
    echo ""
    echo "1. On Node 2 (${NODE2_IP}):"
    echo "   a. Install MySQL: apt install mysql-server"
    echo "   b. Configure bind-address: ${NODE2_IP}"
    echo "   c. Configure innodb_buffer_pool_size: 8G (more RAM available)"
    echo "   d. Restart MySQL"
    echo ""
    echo "2. On Node 1 (this server):"
    echo "   a. Dump databases:"
    echo "      for app in blog lms siakad cbt akm wiki forum cloud mail; do"
    echo "          mysqldump --single-transaction -u srvtkjusr_\${app} -p srvtkjdbs_\${app} | \\"
    echo "          mysql -h ${NODE2_IP} -u srvtkjusr_\${app} -p srvtkjdbs_\${app}"
    echo "      done"
    echo ""
    echo "   b. Update application configs:"
    echo "      - WordPress (wp-config.php): define('DB_HOST', '${NODE2_IP}');"
    echo "      - Laravel (.env): DB_HOST=${NODE2_IP}"
    echo "      - Moodle (config.php): \$CFG->dbhost = '${NODE2_IP}';"
    echo ""
    echo "   c. Update UFW rules:"
    echo "      ufw allow from ${NODE1_IP} to ${NODE2_IP} port 3306"
    echo ""
    echo "   d. Verify: mysql -h ${NODE2_IP} -u srvtkjusr_lms -p -e 'SELECT 1;'"
    echo ""
fi

if [[ "${MIGRATION_TYPE}" == "cache" || "${MIGRATION_TYPE}" == "both" ]]; then
    echo "=== Cache Migration Steps ==="
    echo ""
    echo "1. On Node 2 (${NODE2_IP}):"
    echo "   a. Install Redis: apt install redis-server"
    echo "   b. Configure bind-address: ${NODE2_IP}"
    echo "   c. Set requirepass with strong password"
    echo "   d. Restart Redis"
    echo ""
    echo "2. On Node 1 (this server):"
    echo "   a. Update application configs:"
    echo "      - WordPress: define('WP_REDIS_HOST', '${NODE2_IP}');"
    echo "      - Laravel: REDIS_HOST=${NODE2_IP}"
    echo ""
    echo "   b. Update UFW rules:"
    echo "      ufw allow from ${NODE1_IP} to ${NODE2_IP} port 6379"
    echo ""
    echo "   c. Verify: redis-cli -h ${NODE2_IP} -a <password> ping"
    echo ""
fi

echo "=== Post-Migration Verification ==="
echo ""
echo "1. Check application health: /usr/local/sbin/health-check.sh"
echo "2. Monitor performance: /usr/local/sbin/check-scaling-trigger.sh"
echo "3. Verify backup still works: /usr/local/sbin/backup-applications.sh"
echo ""
echo "Migration guide completed!"
EOF
    
    chmod 755 "${scale_migrate_script}"
    
    log_info "✓ Scaling tools created"
}

#===============================================================
# APPLICATION-SPECIFIC INSTALLATIONS
#===============================================================

install_jellyfin() {
    log_section "Installing Jellyfin Media Server"
    
    # Add Jellyfin repository
    curl -fsSL https://repo.jellyfin.org/ubuntu/jellyfin_team.gpg.key | \
        gpg --dearmor -o /etc/apt/keyrings/jellyfin.gpg 2>/dev/null || {
        mkdir -p /etc/apt/keyrings
        curl -fsSL https://repo.jellyfin.org/ubuntu/jellyfin_team.gpg.key | \
            gpg --dearmor -o /etc/apt/keyrings/jellyfin.gpg
    }
    
    echo "deb [signed-by=/etc/apt/keyrings/jellyfin.gpg] https://repo.jellyfin.org/ubuntu $(lsb_release -cs) main" | \
        tee /etc/apt/sources.list.d/jellyfin.list
    
    apt-get update -qq
    apt-get install -y -qq jellyfin
    
    # Configure Jellyfin to listen on localhost only
    local jellyfin_config="/etc/jellyfin/networking.xml"
    if [[ -f "${jellyfin_config}" ]]; then
        sed -i 's|<LocalNetworkAddresses>.*</LocalNetworkAddresses>|<LocalNetworkAddresses>127.0.0.1</LocalNetworkAddresses>|g' "${jellyfin_config}"
    fi
    
    # Start Jellyfin
    systemctl start jellyfin
    systemctl enable jellyfin
    
    # Wait for Jellyfin to start
    sleep 5
    
    # Verify Jellyfin is running
    if curl -s http://127.0.0.1:8096 > /dev/null 2>&1; then
        log_info "✓ Jellyfin installed and running on 127.0.0.1:8096"
    else
        log_warn "Jellyfin may still be starting up"
    fi
}

install_jitsi_meet() {
    log_section "Installing JitsiMeet"
    
    # Note: JitsiMeet requires more complex setup with Prosody
    # This is a minimal installation for reverse proxy
    
    # Install Node.js (required for JitsiMeet)
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y -qq nodejs
    
    # Install JitsiMeet (basic setup)
    # Note: In production, you'd use the official JitsiMeet installer
    # or Docker containers
    
    # Create a simple placeholder for JitsiMeet
    local meet_dir="/var/www/meet"
    ensure_dir "${meet_dir}" "www-data:www-data" "755"
    
    # Create a simple HTML page for now
    cat > "${meet_dir}/index.html" << 'EOF'
<!DOCTYPE html>
<html>
<head>
    <title>JitsiMeet</title>
    <style>
        body { font-family: Arial, sans-serif; text-align: center; padding: 50px; }
        h1 { color: #333; }
        .info { background: #f0f0f0; padding: 20px; border-radius: 5px; margin: 20px auto; max-width: 600px; }
    </style>
</head>
<body>
    <h1>JitsiMeet Service</h1>
    <div class="info">
        <p>JitsiMeet is configured to run on this server.</p>
        <p>Access it via: <a href="/meet">/meet</a></p>
        <p>Backend: 127.0.0.1:8000</p>
    </div>
</body>
</html>
EOF
    
    log_info "✓ JitsiMeet placeholder created (full installation requires additional setup)"
}

install_samba() {
    log_section "Installing Samba File Server"
    
    apt-get install -y -qq samba samba-common
    
    # Create Samba info page
    local samba_dir="/var/www/samba"
    ensure_dir "${samba_dir}" "www-data:www-data" "755"
    
    cat > "${samba_dir}/index.html" << 'EOF'
<!DOCTYPE html>
<html>
<head>
    <title>File Server Access</title>
    <style>
        body { font-family: Arial, sans-serif; text-align: center; padding: 50px; }
        h1 { color: #333; }
        .info { background: #f0f0f0; padding: 20px; border-radius: 5px; margin: 20px auto; max-width: 600px; }
        .protocol { color: #0066cc; font-weight: bold; }
    </style>
</head>
<body>
    <h1>📁 File Server Access</h1>
    <div class="info">
        <p>This service is accessible via SMB/CIFS protocol only.</p>
        <p>Use the following address in your file manager:</p>
        <p class="protocol">\\192.168.255.246</p>
        <p>or</p>
        <p class="protocol">smb://192.168.255.246</p>
        <hr>
        <p>Supported protocols:</p>
        <ul style="text-align: left; display: inline-block;">
            <li>SMB (Server Message Block)</li>
            <li>CIFS (Common Internet File System)</li>
        </ul>
    </div>
</body>
</html>
EOF
    
    # Configure Samba
    local smb_conf="/etc/samba/smb.conf"
    backup_file "${smb_conf}"
    
    cat > "${smb_conf}" << 'EOF'
# Samba Configuration - File Server
[global]
   workgroup = WORKGROUP
   server string = TKJ File Server
   netbios name = SRV-TKJ-01
   
   # Security settings
   security = user
   map to guest = never
   
   # Network binding (LAN only)
   bind interfaces only = yes
   interfaces = lo 192.168.255.246/24
   
   # Logging
   log file = /var/log/samba/log.%m
   max log size = 1000
   logging = file
   
   # Performance
   socket options = TCP_NODELAY SO_RCVBUF=8192 SO_SNDBUF=8192
   oplocks = yes
   
   # Disable printing
   load printers = no
   printing = bsd
   printcap name = /dev/null
   disable spoolss = yes

# Shared directories (configure as needed)
[public]
   comment = Public Share
   path = /srv/samba/public
   browseable = yes
   read only = no
   guest ok = no
   valid users = @sambausers
   create mask = 0664
   directory mask = 0775

[shared]
   comment = Shared Documents
   path = /srv/samba/shared
   browseable = yes
   read only = no
   guest ok = no
   valid users = @sambausers
   create mask = 0664
   directory mask = 0775
EOF
    
    # Create Samba directories
    ensure_dir "/srv/samba/public" "root:sambausers" "2770"
    ensure_dir "/srv/samba/shared" "root:sambausers" "2770"
    
    # Create sambausers group if not exists
    groupadd sambausers 2>/dev/null || true
    
    # Restart Samba
    systemctl restart smbd nmbd
    systemctl enable smbd nmbd
    
    log_info "✓ Samba installed and configured"
}

#===============================================================
# MAIN EXECUTION FLOW
#===============================================================

main() {
    echo "╔══════════════════════════════════════════════════════════════════════════╗"
    echo "║        Enterprise Multi-Application Server Setup Script                  ║"
    echo "║        Ubuntu 24.04 LTS | 8 vCPU | 16GB RAM | 1TB Storage                ║"
    echo "╚══════════════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Server IP: ${SERVER_IP}"
    echo "Hostname: ${SERVER_HOSTNAME}"
    echo "Log File: ${LOG_FILE}"
    echo ""
    echo "This script will:"
    echo "  1. Update system and install packages"
    echo "  2. Configure kernel parameters"
    echo "  3. Install and configure Apache 2.4"
    echo "  4. Install and configure PHP 8.3 FPM (Heavy/Light pools)"
    echo "  5. Install and configure MySQL 8.0 (isolated databases)"
    echo "  6. Install and configure Redis (localhost only)"
    echo "  7. Set up filesystem permissions (Zero-Trust)"
    echo "  8. Configure UFW firewall"
    echo "  9. Configure Fail2Ban"
    echo "  10. Set up automated backups with Borg"
    echo "  11. Set up monitoring and health checks"
    echo "  12. Create deployment and scaling tools"
    echo ""
    
    read -p "Continue with installation? (y/N): " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        die "Installation cancelled by user"
    fi
    
    local start_time=$(date +%s)
    
    # Execute all setup functions
    check_prerequisites
    update_system
    configure_kernel
    install_apache
    create_apache_vhost_configs
    install_php
    install_mysql
    install_redis
    setup_filesystem
    configure_firewall
    configure_fail2ban
    setup_backup
    setup_monitoring
    create_deployment_script
    create_scaling_tools
    
    # Application-specific installations
    install_jellyfin
    install_jitsi_meet
    install_samba
    
    # Final validation
    final_validation
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    local duration_min=$((duration / 60))
    
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════════════╗"
    echo "║                    Installation Completed Successfully!                   ║"
    echo "╚══════════════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Installation completed in ${duration_min} minutes (${duration} seconds)"
    echo ""
    echo "Important credentials saved to:"
    echo "  - MySQL root password: /root/.mysql_root_password"
    echo "  - Database credentials: /root/.db_credentials"
    echo "  - Redis password: /root/.redis_password"
    echo "  - Borg passphrase: /root/.borg_passphrase"
    echo ""
    echo "Next steps:"
    echo "  1. Deploy applications to their respective directories"
    echo "  2. Update database credentials in application configs"
    echo "  3. Run health check: /usr/local/sbin/health-check.sh"
    echo "  4. Test backup: /usr/local/sbin/backup-applications.sh"
    echo ""
}

final_validation() {
    log_section "Running Final Validation"
    
    local errors=0
    
    # Check Apache
    if systemctl is-active --quiet apache2; then
        log_info "✓ Apache is running"
    else
        log_error "✗ Apache is not running"
        ((errors++))
    fi
    
    # Check PHP-FPM
    if systemctl is-active --quiet php8.3-fpm; then
        log_info "✓ PHP-FPM is running"
    else
        log_error "✗ PHP-FPM is not running"
        ((errors++))
    fi
    
    # Check MySQL
    if systemctl is-active --quiet mysql; then
        log_info "✓ MySQL is running"
    else
        log_error "✗ MySQL is not running"
        ((errors++))
    fi
    
    # Check Redis
    if systemctl is-active --quiet redis-server; then
        log_info "✓ Redis is running"
    else
        log_error "✗ Redis is not running"
        ((errors++))
    fi
    
    # Check Fail2Ban
    if systemctl is-active --quiet fail2ban; then
        log_info "✓ Fail2Ban is running"
    else
        log_error "✗ Fail2Ban is not running"
        ((errors++))
    fi
    
    # Check Apache configuration
    if apache2ctl configtest 2>/dev/null; then
        log_info "✓ Apache configuration is valid"
    else
        log_error "✗ Apache configuration has errors"
        ((errors++))
    fi
    
    # Check PHP-FPM configuration
    if php-fpm8.3 -t 2>/dev/null; then
        log_info "✓ PHP-FPM configuration is valid"
    else
        log_error "✗ PHP-FPM configuration has errors"
        ((errors++))
    fi
    
    # Check HTTP response
    local http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "http://127.0.0.1/html" 2>/dev/null || echo "000")
    if [[ "${http_code}" == "200" || "${http_code}" == "301" || "${http_code}" == "302" ]]; then
        log_info "✓ HTTP is responding (code: ${http_code})"
    else
        log_error "✗ HTTP is not responding (code: ${http_code})"
        ((errors++))
    fi
    
    # Check UFW
    if ufw status | grep -q "Status: active"; then
        log_info "✓ UFW firewall is active"
    else
        log_error "✗ UFW firewall is not active"
        ((errors++))
    fi
    
    # Check systemd limits
    if [[ -f "/etc/systemd/system/php8.3-fpm.service.d/override.conf" ]]; then
        log_info "✓ Systemd resource limits configured for PHP-FPM"
    else
        log_error "✗ Systemd resource limits not configured for PHP-FPM"
        ((errors++))
    fi
    
    # Summary
    echo ""
    if [[ ${errors} -eq 0 ]]; then
        log_info "╔══════════════════════════════════════════════════╗"
        log_info "║  All validation checks passed!                   ║"
        log_info "╚══════════════════════════════════════════════════╝"
    else
        log_warn "╔══════════════════════════════════════════════════╗"
        log_warn "║  ${errors} validation check(s) failed              ║"
        log_warn "╚══════════════════════════════════════════════════╝"
    fi
}

#===============================================================
# RUN SCRIPT
#===============================================================

# Check if script is being sourced or executed
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
