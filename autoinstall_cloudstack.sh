#!/usr/bin/env bash
#=====================================================================
# CloudStack installer – Enhanced version with rollback & validation
#=====================================================================
#  • Input validation with retry capability
#  • Network operation retry logic
#  • MySQL and NFS mount verification
#  • Rollback capabilities
#  • Uninstall option
#  • Idempotent package installation
#=====================================================================

set -euo pipefail
IFS=$'\n\t'

# -----------------------------------------------------------------
# LOGGING SETUP
# -----------------------------------------------------------------
LOGFILE="/var/log/cloudstack-installer-$(date +%Y%m%d-%H%M%S).log"
ROLLBACK_LOG="/var/log/cloudstack-rollback-$(date +%Y%m%d-%H%M%S).log"
if [[ ! -d /var/log ]]; then
    LOGFILE="/tmp/cloudstack-installer-$(date +%Y%m%d-%H%M%S).log"
    ROLLBACK_LOG="/tmp/cloudstack-rollback-$(date +%Y%m%d-%H%M%S).log"
fi

touch "$LOGFILE" 2>/dev/null || {
    echo "ERROR: Cannot create log file at $LOGFILE. Aborting." >&2
    exit 1
}
chmod 644 "$LOGFILE"

# Rollback tracking
declare -a ROLLBACK_ACTIONS=()
declare -a NEWLY_INSTALLED_PACKAGES=()

log_setup() {
    if command -v tee >/dev/null; then
        exec > >(tee -a "$LOGFILE") 2>&1
    else
        exec > "$LOGFILE" 2>&1
    fi
}

log_setup

{
    echo "[$(date)] CloudStack Installer Started"
    echo "[$(date)] User: $(whoami)"
    echo "[$(date)] Host: $(hostname)"
    echo "[$(date)] Script: $0"
    echo "[$(date)] Arguments: $*"
    echo "[$(date)] Log file: $LOGFILE"
    echo "[$(date)] Rollback log: $ROLLBACK_LOG"
    echo "[$(date)] ========================================"
} | tee -a "$LOGFILE" 2>/dev/null || cat >>"$LOGFILE"

# -----------------------------------------------------------------
# Colors and formatting
# -----------------------------------------------------------------
tput_safe() { tput "$@" 2>/dev/null || true; }

COLUMNS="$(tput_safe cols || echo 80)"
R="$(tput_safe setaf 1)"
B="$(tput_safe setaf 6)"
Y="$(tput_safe setaf 3)"
G="$(tput_safe setaf 2)"
BL="$(tput_safe blink)"
b="$(tput_safe bold)"
N="$(tput_safe sgr0)"

# -----------------------------------------------------------------
# Option flags
# -----------------------------------------------------------------
opt_agent=false
opt_common=false
opt_nfs=false
opt_management=false
opt_reboot=false
opt_webmin=false
opt_uninstall=false

# -----------------------------------------------------------------
# Variables
# -----------------------------------------------------------------
VER=""
VERs=""
MYPASS=""
HOSTNAME=""
IPADDR=""
CIDR=""
GATEWAY=""
DNS1="" 
DNS2=""
CON=""
NFS_SERVER_IP=""
NFS_SERVER_PRIMARY=""
NFS_SERVER_SECONDARY=""
NETWORK=""
SSH_PUBLIC_KEY='insert_your_ssh_public_key_here'

# Network retry settings
MAX_RETRIES=3
RETRY_DELAY=5

# Package manager variable
PKG_MGR=""

# -----------------------------------------------------------------
# Logging helpers
# -----------------------------------------------------------------
info()  { 
    printf "%b%b[INFO] %b %b%s%b\n" "$b" "$G" "$N" "$b" "$B" "$*" "$N"
    printf "[INFO] %s\n" "$*" >> "$LOGFILE"
}

warn()  { 
    printf "%b%b[WARN] %b %b%s%b\n" "$b" "$Y" "$N" "$b" "$B" "$*" "$N" >&2
    printf "[WARN] %s\n" "$*" >> "$LOGFILE"
    sleep 3
}

fatal() { 
    printf "%b%b[ERROR] %b %b%s%b\n" "$b" "$R" "$N" "$b" "$B" "$*" "$N" >&2
    printf "[ERROR] %s\n" "$*" >> "$LOGFILE"
    {
        echo "[$(date)] ========================================"
        echo "[$(date)] Installation FAILED"
        echo "[$(date)] Log file: $LOGFILE"
        echo "[$(date)] Initiating rollback..."
    } | tee -a "$LOGFILE" 2>/dev/null || cat >>"$LOGFILE"
    
    perform_rollback
    exit 1
}

# -----------------------------------------------------------------
# Rollback functionality
# -----------------------------------------------------------------
add_rollback_action() {
    local action="$1"
    ROLLBACK_ACTIONS+=("$action")
    echo "[$(date)] Rollback action registered: $action" >> "$ROLLBACK_LOG"
}

# -----------------------------------------------------------------
# Enhanced rollback with network restoration
# -----------------------------------------------------------------
perform_rollback() {
    if [[ ${#ROLLBACK_ACTIONS[@]} -eq 0 ]]; then
        info "No rollback actions to perform."
        return
    fi
    
    warn "Performing rollback of ${#ROLLBACK_ACTIONS[@]} actions..."
    
    # Execute rollback actions in reverse order
    for ((i=${#ROLLBACK_ACTIONS[@]}-1; i>=0; i--)); do
        local action="${ROLLBACK_ACTIONS[$i]}"
        info "Rollback: $action"
        
        # Special handling for network restore
        if [[ "$action" == "restore_network_config" ]]; then
            restore_network_config
        else
            eval "$action" 2>&1 | tee -a "$ROLLBACK_LOG" || warn "Rollback action failed: $action"
        fi
    done
    
    info "Rollback completed. See $ROLLBACK_LOG for details."
    
    # Show network status after rollback
    if command -v nmcli >/dev/null; then
        echo
        info "Current network connections after rollback:"
        nmcli connection show
    fi
}
# -----------------------------------------------------------------
# Network configuration backup and restore
# -----------------------------------------------------------------
backup_network_config() {
    local backup_dir="/var/lib/cloudstack-installer-backup"
    mkdir -p "$backup_dir"
    
    info "Backing up network configuration..."
    
    # Backup all NetworkManager connections
    if command -v nmcli >/dev/null; then
        # Export current connection list
        nmcli -t -f NAME,UUID,TYPE connection show > "$backup_dir/nmcli-connections.txt"
        
        # Backup connection files
        if [[ -d /etc/NetworkManager/system-connections ]]; then
            mkdir -p "$backup_dir/system-connections"
            cp -a /etc/NetworkManager/system-connections/* "$backup_dir/system-connections/" 2>/dev/null || true
        fi
        
        # Backup old-style network scripts if they exist
        if [[ -d /etc/sysconfig/network-scripts ]]; then
            mkdir -p "$backup_dir/network-scripts"
            cp -a /etc/sysconfig/network-scripts/ifcfg-* "$backup_dir/network-scripts/" 2>/dev/null || true
        fi
        
        add_rollback_action "restore_network_config"
    fi
}

restore_network_config() {
    local backup_dir="/var/lib/cloudstack-installer-backup"
    
    if [[ ! -d "$backup_dir" ]]; then
        warn "No network backup found at $backup_dir"
        return 0
    fi
    
    info "Restoring network configuration..."
    
    if ! command -v nmcli >/dev/null; then
        warn "nmcli not available - cannot restore network config"
        return 0
    fi
    
    # Delete CloudStack-created bridges
    info "Removing CloudStack network bridges..."
    nmcli connection delete cloudbr0 2>/dev/null || true
    nmcli connection delete cloudbr1 2>/dev/null || true
    
    # Delete any bridge-slave connections we created
    while IFS= read -r line; do
        local conn_name=$(echo "$line" | cut -d: -f1)
        local conn_type=$(echo "$line" | cut -d: -f3)
        
        # Remove bridge-slave connections (these were created by the installer)
        if [[ "$conn_type" == "bridge-slave" ]]; then
            info "Removing bridge-slave connection: $conn_name"
            nmcli connection delete "$conn_name" 2>/dev/null || true
        fi
    done < <(nmcli -t -f NAME,UUID,TYPE connection show 2>/dev/null)
    
    # Restore original connection files
    if [[ -d "$backup_dir/system-connections" ]]; then
        info "Restoring NetworkManager connection files..."
        cp -a "$backup_dir/system-connections"/* /etc/NetworkManager/system-connections/ 2>/dev/null || true
    fi
    
    if [[ -d "$backup_dir/network-scripts" ]]; then
        info "Restoring network-scripts..."
        cp -a "$backup_dir/network-scripts"/* /etc/sysconfig/network-scripts/ 2>/dev/null || true
    fi
    
    # Reload NetworkManager to apply restored configs
    info "Reloading NetworkManager..."
    systemctl reload NetworkManager || systemctl restart NetworkManager || true
    
    # Wait for network to stabilize
    sleep 5
    
    # Bring up original connections from backup
    if [[ -f "$backup_dir/nmcli-connections.txt" ]]; then
        while IFS=: read -r conn_name conn_uuid conn_type; do
            # Skip bridge types (those were created by installer)
            if [[ "$conn_type" != "bridge" && "$conn_type" != "bridge-slave" ]]; then
                info "Activating original connection: $conn_name"
                nmcli connection up "$conn_name" 2>/dev/null || true
            fi
        done < "$backup_dir/nmcli-connections.txt"
    fi
    
    info "Network configuration restored"
    info "You may need to reconnect to this system if the IP address changed"
}

# -----------------------------------------------------------------
# **NEW – Service enable/disable with rollback**
# -----------------------------------------------------------------
enable_service_with_rollback() {
    local service_name="$1"
    
    # If the service is already enabled, just note it
    if systemctl is-enabled "$service_name" &>/dev/null; then
        info "Service already enabled: $service_name"
        return 0
    fi
    
    # Enable and start the service
    systemctl enable --now "$service_name" || fatal "Failed to enable $service_name"
    info "Service enabled and started: $service_name"
    
    # Register rollback: disable and stop
    add_rollback_action "systemctl disable $service_name; systemctl stop $service_name || true"
}

# -----------------------------------------------------------------
# Package management helpers (SIMPLER FIX)
# -----------------------------------------------------------------
is_package_installed() {
    local package="$1"
    
    if [[ "$PKG_MGR" == "dnf" ]] || [[ "$PKG_MGR" == "yum" ]]; then
        rpm -q "$package" &>/dev/null
    else
        return 1
    fi
}

check_packages_installed() {
    local packages=("$@")
    local not_installed=()
    
    for pkg in "${packages[@]}"; do
        if ! is_package_installed "$pkg"; then
            not_installed+=("$pkg")
        fi
    done
    
    # Return only package names, no other output
    printf '%s\n' "${not_installed[@]}"
}

# -----------------------------------------------------------------
# Clean empty entries from package arrays
# -----------------------------------------------------------------
clean_pkg_array() {
    # $1 is the name of the array variable (passed by name)
    local -n arr=$1
    # Remove empty entries (they appear when all packages are already installed)
    local filtered=()
    for p in "${arr[@]}"; do
        [[ -n $p ]] && filtered+=("$p")
    done
    arr=("${filtered[@]}")
}

# -----------------------------------------------------------------
# Network retry wrapper
# -----------------------------------------------------------------
retry_command() {
    local max_attempts="$1"
    shift
    local attempt=1
    
    while (( attempt <= max_attempts )); do
        info "Attempt $attempt/$max_attempts: $*"
        
        if "$@"; then
            info "Command succeeded: $*"
            return 0
        fi
        
        if (( attempt < max_attempts )); then
            warn "Command failed, retrying in ${RETRY_DELAY}s..."
            sleep "$RETRY_DELAY"
        fi
        
        ((attempt++))
    done
    
    fatal "Command failed after $max_attempts attempts: $*"
}

# -----------------------------------------------------------------
# Download with retry
# -----------------------------------------------------------------
download_with_retry() {
    local url="$1"
    local output="$2"
    
    retry_command "$MAX_RETRIES" curl -fsSL --connect-timeout 30 --max-time 300 -o "$output" "$url"
}

# -----------------------------------------------------------------
# DNF/YUM with retry and idempotency (FIXED)
# -----------------------------------------------------------------
package_install_retry() {
    local pkg_mgr="$1"
    shift
    local packages=("$@")
    
    # Filter out already installed packages
    local not_installed=()
    
    # Capture output properly using mapfile/readarray
    while IFS= read -r pkg; do
        [[ -n "$pkg" ]] && not_installed+=("$pkg")
    done < <(check_packages_installed "${packages[@]}")
    
    # Show which packages are already installed
    local already_installed=()
    for pkg in "${packages[@]}"; do
        if is_package_installed "$pkg"; then
            already_installed+=("$pkg")
        fi
    done
    
    if (( ${#already_installed[@]} > 0 )); then
        info "Already installed: ${already_installed[*]}"
    fi
    
    if (( ${#not_installed[@]} == 0 )); then
        info "All requested packages are already installed"
        return 0
    fi
    
    info "Installing missing packages: ${not_installed[*]}"
    
    # Track newly installed packages for rollback
    if retry_command "$MAX_RETRIES" "$pkg_mgr" install -y "${not_installed[@]}"; then
        for pkg in "${not_installed[@]}"; do
            if is_package_installed "$pkg"; then
                NEWLY_INSTALLED_PACKAGES+=("$pkg")
                info "Successfully installed: $pkg"
            fi
        done
        # Use --noautoremove to avoid removing user-installed dependencies
        add_rollback_action "$pkg_mgr remove -y ${not_installed[*]} --noautoremove || true"
    else
        fatal "Failed to install packages: ${not_installed[*]}"
    fi
}

# -----------------------------------------------------------------
# RPM install with retry and idempotency (COMPLETE FIX)
# -----------------------------------------------------------------
rpm_install_retry() {
    local rpm_url="$1"
    local temp_rpm="/tmp/$(basename "$rpm_url")"
    
    # Download first (with retry)
    if ! download_with_retry "$rpm_url" "$temp_rpm"; then
        warn "Failed to download RPM from $rpm_url"
        return 0
    fi
    
    # Extract package name properly using rpm query
    local pkg_name
    pkg_name="$(rpm -qp --queryformat '%{NAME}' "$temp_rpm" 2>/dev/null)" || {
        warn "Could not query RPM package name from $rpm_url"
        rm -f "$temp_rpm"
        return 0
    }
    
    # Check if already installed BEFORE attempting install
    if is_package_installed "$pkg_name"; then
        info "RPM already installed: $pkg_name"
        rm -f "$temp_rpm"
        return 0
    fi
    
    info "Installing RPM: $pkg_name"
    
    # Use rpm -U (upgrade) which handles both install and upgrade
    # Don't use retry_command here - we already checked if installed
    local attempt=1
    while (( attempt <= MAX_RETRIES )); do
        if rpm -U "$temp_rpm" 2>/dev/null; then
            info "Successfully installed RPM: $pkg_name"
            NEWLY_INSTALLED_PACKAGES+=("$pkg_name")
            add_rollback_action "rpm -e $pkg_name --nodeps || true"
            rm -f "$temp_rpm"
            return 0
        fi
        
        # Check if it got installed despite the error
        if is_package_installed "$pkg_name"; then
            info "RPM is now installed: $pkg_name"
            rm -f "$temp_rpm"
            return 0
        fi
        
        if (( attempt < MAX_RETRIES )); then
            warn "RPM install attempt $attempt failed, retrying..."
            sleep 2
        fi
        ((attempt++))
    done
    
    # Final check
    if is_package_installed "$pkg_name"; then
        info "RPM is installed: $pkg_name"
        rm -f "$temp_rpm"
        return 0
    else
        warn "Failed to install RPM: $pkg_name (continuing anyway)"
        rm -f "$temp_rpm"
        return 0
    fi
}

# -----------------------------------------------------------------
# DNF group install with retry
# -----------------------------------------------------------------
group_install_retry() {
    local pkg_mgr="$1"
    local group_name="$2"
    
    info "Installing package group: $group_name"
    
    # Check if group is already installed
    if "$pkg_mgr" group list --installed 2>/dev/null | grep -q "$group_name"; then
        info "Package group already installed: $group_name"
        return 0
    fi
    
    if retry_command "$MAX_RETRIES" "$pkg_mgr" groupinstall -y "$group_name"; then
        info "Successfully installed group: $group_name"
        add_rollback_action "$pkg_mgr groupremove -y '$group_name' || true"
        return 0
    else
        warn "Failed to install group: $group_name (continuing anyway)"
        return 0  # Don't fail the entire installation
    fi
}

# -----------------------------------------------------------------
# Input validation helpers
# -----------------------------------------------------------------
validate_ip() {
    local ip="$1"
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        local IFS='.'
        local -a octets=($ip)
        for octet in "${octets[@]}"; do
            if (( octet > 255 )); then
                return 1
            fi
        done
        return 0
    fi
    return 1
}

validate_cidr() {
    local cidr="$1"
    if [[ $cidr =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        local ip="${cidr%/*}"
        local mask="${cidr#*/}"
        if validate_ip "$ip" && (( mask >= 0 && mask <= 32 )); then
            return 0
        fi
    fi
    return 1
}

validate_hostname() {
    local hostname="$1"
    if [[ $hostname =~ ^(([a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9\-]*[a-zA-Z0-9])\.)*([A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9\-]*[A-Za-z0-9])$ ]]; then
        return 0
    fi
    return 1
}

validate_version() {
    local version="$1"
    if [[ $version =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        return 0
    fi
    return 1
}

validate_path() {
    local path="$1"
    if [[ $path =~ ^/[a-zA-Z0-9/_-]+$ ]]; then
        return 0
    fi
    return 1
}

# -----------------------------------------------------------------
# Enhanced input prompts with validation and editing
# -----------------------------------------------------------------
read_with_validation() {
    local prompt="$1"
    local validator="$2"
    local var_name="$3"
    local is_password="${4:-false}"
    local value=""
    
    while true; do
        if [[ "$is_password" == "true" ]]; then
            read -rsp "$prompt" value
            echo
        else
            read -rep "$prompt" value
        fi
        
        # Allow user to review and edit
        if [[ "$is_password" != "true" && -n "$value" ]]; then
            read -rp "You entered: '$value'. Is this correct? (y/n/edit): " confirm
            case "$confirm" in
                y|Y|yes|YES)
                    ;;
                e|E|edit|EDIT)
                    continue
                    ;;
                *)
                    continue
                    ;;
            esac
        fi
        
        # Validate input
        if [[ -n "$validator" ]]; then
            if $validator "$value"; then
                eval "$var_name='$value'"
                return 0
            else
                warn "Invalid input. Please try again."
                continue
            fi
        else
            eval "$var_name='$value'"
            return 0
        fi
    done
}

# -----------------------------------------------------------------
# Interactive prompts with validation
# -----------------------------------------------------------------
get_network_info() {
    echo
    info "=== Network Configuration ==="
    
    read_with_validation 'CloudStack full version (e.g. 4.20.2): ' validate_version VER
    read_with_validation 'CloudStack short version (e.g. 4.20): ' validate_version VERs
    read_with_validation 'MySQL root password: ' '' MYPASS true
    
    # Confirm password
    local pass_confirm=""
    read -rsp 'Confirm MySQL root password: ' pass_confirm
    echo
    while [[ "$pass_confirm" != "$MYPASS" ]]; do
        warn "Passwords do not match!"
        read_with_validation 'MySQL root password: ' '' MYPASS true
        read -rsp 'Confirm MySQL root password: ' pass_confirm
        echo
    done
    
    read_with_validation 'Hostname (e.g. cloudstack): ' validate_hostname HOSTNAME
    read_with_validation 'IP address (e.g. 192.168.1.2): ' validate_ip IPADDR
    
    # CIDR with default
    local cidr_input=""
    read_with_validation "Network CIDR (press Enter for ${IPADDR}/24): " '' cidr_input
    if [[ -z "$cidr_input" ]]; then
        CIDR="${IPADDR}/24"
    else
        while ! validate_cidr "$cidr_input"; do
            warn "Invalid CIDR format"
            read_with_validation "Network CIDR: " '' cidr_input
        done
        CIDR="$cidr_input"
    fi
    
    read_with_validation 'Gateway (e.g. 192.168.1.1): ' validate_ip GATEWAY
    read_with_validation 'DNS1 (e.g. 192.168.1.1): ' validate_ip DNS1
    read_with_validation 'DNS2 (e.g. 8.8.4.4): ' validate_ip DNS2
    read_with_validation 'Network interface (e.g. eno1 or eth0): ' '' CON
    
    # Summary
    echo
    info "=== Configuration Summary ==="
    echo "Version: $VER ($VERs)"
    echo "Hostname: $HOSTNAME"
    echo "IP/CIDR: $CIDR"
    echo "Gateway: $GATEWAY"
    echo "DNS: $DNS1, $DNS2"
    echo "Interface: $CON"
    echo
    
    read -rp "Proceed with this configuration? (yes/no): " final_confirm
    if [[ "$final_confirm" != "yes" ]]; then
        info "Restarting configuration..."
        get_network_info
    fi
}

get_nfs_info() {
    echo
    info "=== NFS Configuration ==="
    
    read_with_validation 'NFS server IP: ' validate_ip NFS_SERVER_IP
    read_with_validation 'Primary export path (e.g. /export/primary): ' validate_path NFS_SERVER_PRIMARY
    read_with_validation 'Secondary export path (e.g. /export/secondary): ' validate_path NFS_SERVER_SECONDARY
    
    echo
    info "=== NFS Configuration Summary ==="
    echo "NFS Server: $NFS_SERVER_IP"
    echo "Primary: $NFS_SERVER_PRIMARY"
    echo "Secondary: $NFS_SERVER_SECONDARY"
    echo
    
    read -rp "Proceed with this configuration? (yes/no): " final_confirm
    if [[ "$final_confirm" != "yes" ]]; then
        info "Restarting NFS configuration..."
        get_nfs_info
    fi
}

get_nfs_network() {
    echo
    read_with_validation 'Accept NFS client access from (e.g. 192.168.1.0/24): ' validate_cidr NETWORK
}

# -----------------------------------------------------------------
# NFS mount verification
# -----------------------------------------------------------------
verify_nfs_mount() {
    local mount_point="$1"
    local nfs_server="$2"
    local nfs_path="$3"
    
    info "Verifying NFS mount at $mount_point..."
    
    if ! mountpoint -q "$mount_point"; then
        warn "Mount point $mount_point is not mounted, attempting mount..."
        retry_command "$MAX_RETRIES" mount -t nfs "${nfs_server}:${nfs_path}" "$mount_point"
    fi
    
    if mountpoint -q "$mount_point"; then
        # Test write access
        local test_file="${mount_point}/.cloudstack_test_$$"
        if touch "$test_file" 2>/dev/null; then
            rm -f "$test_file"
            info "NFS mount $mount_point is working and writable"
            return 0
        else
            fatal "NFS mount $mount_point is not writable"
        fi
    else
        fatal "Failed to mount NFS at $mount_point"
    fi
}

# -----------------------------------------------------------------
# SSH key helper
# -----------------------------------------------------------------
add_ssh_public_key() {
    [[ -z "$SSH_PUBLIC_KEY" || "$SSH_PUBLIC_KEY" == insert_your_ssh_public_key_here ]] && {
        warn "SSH_PUBLIC_KEY not set – skipping key installation."
        return
    }
    local ssh_dir="${HOME:-/root}/.ssh"
    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"
    
    grep -qxF -- "$SSH_PUBLIC_KEY" "$ssh_dir/authorized_keys" 2>/dev/null ||
        printf '%s\n' "$SSH_PUBLIC_KEY" >>"$ssh_dir/authorized_keys"
    chmod 600 "$ssh_dir/authorized_keys"
    info "SSH public key added (if it wasn't already there)."
    
    add_rollback_action "sed -i '\\|${SSH_PUBLIC_KEY}|d' $ssh_dir/authorized_keys"
}

# -----------------------------------------------------------------
# Safe file writing
# -----------------------------------------------------------------
safe_write_file() {
    local dest="$1"; shift
    local dir
    dir="$(dirname "$dest")"
    mkdir -p "$dir"
    local tmp
    tmp="$(mktemp --tmpdir "$(basename "$dest").XXXXXX")"
    cat >"$tmp" "$@"
    chmod 644 "$tmp" || true
    
    # Backup original if it exists
    if [[ -f "$dest" ]]; then
        cp "$dest" "${dest}.backup.$$"
        add_rollback_action "mv ${dest}.backup.$$ $dest"
    else
        add_rollback_action "rm -f $dest"
    fi
    
    mv "$tmp" "$dest"
}

# -----------------------------------------------------------------
# Banner
# -----------------------------------------------------------------
cat <<'BANNER'
  ╔══════════════════════════════════════════════════════════╗
  ║+-++-++-++-++-++-++-++-++-++-+ +-++-++-++-++-++-++-++-++-+║
  ║|C||l||o||u||d||S||t||a||c||k| |I||n||s||t||a||l||l||e||r|║
  ║+-++-++-++-++-++-++-++-++-++-+ +-++-++-++-++-++-++-++-++-+║
  ╚══════════════════════════════════════════════════════════╝
  processing.................
BANNER
sleep 2

info "**** Current Network Connections ****"
nmcli con show || true
sleep 2

# -----------------------------------------------------------------
# Install common tools (PATCHED with network backup)
# -----------------------------------------------------------------
install_common() {
    info "Installing common tools"

    if command -v dnf >/dev/null; then
        PKG_MGR=dnf
    elif command -v yum >/dev/null; then
        PKG_MGR=yum
    else
        fatal "Neither dnf nor yum found – cannot install packages."
    fi

    retry_command "$MAX_RETRIES" $PKG_MGR update -y
    add_rollback_action "info 'System packages updated - no rollback for updates'"

    # PATCH: SELinux - only runtime change, no grubby modification
    if [[ -f /etc/selinux/config ]]; then
        if ! grep -q '^SELINUX=permissive' /etc/selinux/config; then
            cp /etc/selinux/config /etc/selinux/config.installer-backup
            add_rollback_action "mv /etc/selinux/config.installer-backup /etc/selinux/config"
            sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
        fi
        command -v setenforce >/dev/null && setenforce 0 || true
        info "SELinux set to permissive (runtime and config)"
    fi

    # PATCH: Validate HOSTNAME before writing config
    [[ -z "$VERs" ]] && fatal "Short CloudStack version (VERs) not set."
    [[ -z "$HOSTNAME" ]] && fatal "HOSTNAME not set – cannot proceed with configuration."
    
    safe_write_file /etc/yum.repos.d/CloudStack.repo <<EOF
[cloudstack-$VERs]
name=cloudstack
baseurl=http://download.cloudstack.org/centos/9/$VERs/
enabled=1
gpgcheck=0
EOF

    # Install EPEL and other repos using package manager (more reliable)
    info "Installing repository packages..."
    
    # Try to install via URL first (dnf/yum handle already-installed gracefully)
    $PKG_MGR install -y \
        https://dev.mysql.com/get/mysql84-community-release-el9-1.noarch.rpm \
        https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm \
        https://dl.fedoraproject.org/pub/epel/epel-next-release-latest-9.noarch.rpm \
        2>/dev/null || info "Some repo packages may already be installed"
    
    # Bridge-utils via direct RPM (it's not in standard repos)
    rpm_install_retry "https://dl.fedoraproject.org/pub/epel/9/Everything/x86_64/Packages/b/bridge-utils-1.7.1-3.el9.x86_64.rpm"

    command -v crb >/dev/null && /usr/bin/crb enable || true

    package_install_retry "$PKG_MGR" chrony wget net-tools curl nfs4-acl-tools nfs-utils htop
    
    group_install_retry "$PKG_MGR" 'Development Tools'

    systemctl restart NetworkManager || true
    enable_service_with_rollback chronyd

    safe_write_file /etc/idmapd.conf <<EOF
Domain = $HOSTNAME
EOF

    if [[ -n "$IPADDR" && -n "$HOSTNAME" ]]; then
        local tmp_hosts
        tmp_hosts="$(mktemp)"
        printf '%s %s\n' "$IPADDR" "$HOSTNAME" >"$tmp_hosts"
        grep -v -F -- "$IPADDR $HOSTNAME" /etc/hosts 2>/dev/null >> "$tmp_hosts" || true
        
        if [[ ! -f /etc/hosts.installer-backup ]]; then
            cp /etc/hosts /etc/hosts.installer-backup
            add_rollback_action "mv /etc/hosts.installer-backup /etc/hosts"
        fi
        mv "$tmp_hosts" /etc/hosts
        
        if [[ ! -f /etc/hostname.installer-backup ]]; then
            cp /etc/hostname /etc/hostname.installer-backup 2>/dev/null || true
            add_rollback_action "mv /etc/hostname.installer-backup /etc/hostname"
        fi
        printf '%s\n' "$HOSTNAME" >/etc/hostname
    fi

    # PATCH: Backup network config BEFORE making changes
    if command -v nmcli >/dev/null && [[ -n "$CON" ]]; then
        backup_network_config
        
        info "Configuring network bridges..."
        nmcli c delete cloudbr0 >/dev/null 2>&1 || true
        nmcli c add type bridge ifname cloudbr0 autoconnect yes con-name cloudbr0 \
            stp on ipv4.addresses "$CIDR" ipv4.method manual ipv4.gateway "$GATEWAY" \
            ipv4.dns "$DNS1" +ipv4.dns "$DNS2" ipv6.method disabled >/dev/null 2>&1 || true

        nmcli c delete "$CON" >/dev/null 2>&1 || true
        nmcli c add type bridge-slave autoconnect yes con-name "$CON" ifname "$CON" master cloudbr0 >/dev/null 2>&1 || true
        nmcli con up "$CON" >/dev/null 2>&1 || true

        nmcli c delete cloudbr1 >/dev/null 2>&1 || true
        nmcli c add type bridge ifname cloudbr1 autoconnect yes con-name cloudbr1 stp on ipv6.method disabled >/dev/null 2>&1 || true

        nmcli c delete "$CON.200" >/dev/null 2>&1 || true
        nmcli c add type bridge-slave autoconnect yes con-name "$CON.200" ifname "$CON.200" master cloudbr1 >/dev/null 2>&1 || true
        nmcli con up "$CON.200" >/dev/null 2>&1 || true
    else
        warn "Skipping network bridge configuration (nmcli not available or CON not set)"
    fi

    sleep 2
}

# -----------------------------------------------------------------
# Install Webmin
# -----------------------------------------------------------------
install_webmin() {
    warn "Installing Webmin – comment out this block in the script if you don't want Webmin"
    
    local webmin_script="/tmp/setup-repos.sh"
    download_with_retry "https://raw.githubusercontent.com/webmin/webmin/master/setup-repos.sh" "$webmin_script"
    add_rollback_action "rm -f $webmin_script"
    
    package_install_retry "$PKG_MGR" perl perl-App-cpanminus perl-devel perl-DBD-MySQL
    
    if [[ -f "$webmin_script" ]]; then
        sh "$webmin_script" -f || true
        package_install_retry "$PKG_MGR" webmin
        systemctl enable --now webmin || true
        add_rollback_action "systemctl disable webmin; systemctl stop webmin; $PKG_MGR remove -y webmin"
    fi
}

# -----------------------------------------------------------------
# Install management server (FIXED – robust MySQL password handling)
# -----------------------------------------------------------------
install_management() {
    info "Installing CloudStack management components"
    package_install_retry "$PKG_MGR" cloudstack-management mysql-server mysql-connector-python3

    [[ -z "$MYPASS" ]] && fatal "MySQL password (MYPASS) is empty – aborting."

    # Check if MySQL data directory exists and is properly initialized
    if [[ ! -d /var/lib/mysql/mysql ]]; then
        info "MySQL data directory not found – initializing..."
        
        # Ensure proper ownership before initialization
        mkdir -p /var/lib/mysql
        chown -R mysql:mysql /var/lib/mysql
        chmod 750 /var/lib/mysql
        
        # Initialize with insecure mode (empty root password)
        if ! mysqld --initialize-insecure --user=mysql 2>&1 | tee -a "$LOGFILE"; then
            fatal "MySQL data directory initialization failed. Check $LOGFILE for details."
        fi
        
        info "MySQL data directory initialized successfully"
    else
        info "MySQL data directory already exists"
        
        # Verify ownership
        chown -R mysql:mysql /var/lib/mysql
        chmod 750 /var/lib/mysql
    fi

    # Check for any existing MySQL processes
    if pgrep -x mysqld >/dev/null; then
        warn "Found existing mysqld process – stopping it"
        pkill -9 mysqld || true
        sleep 3
    fi

    # Remove any stale socket or PID files
    rm -f /var/lib/mysql/mysql.sock /var/lib/mysql/mysql.sock.lock
    rm -f /var/run/mysqld/mysqld.pid

    # Ensure mysqld run directory exists
    mkdir -p /var/run/mysqld
    chown mysql:mysql /var/run/mysqld
    chmod 755 /var/run/mysqld

    # Try to start MySQL service
    info "Starting MySQL service..."
    if ! systemctl start mysqld; then
        warn "MySQL failed to start – checking logs..."
        journalctl -xeu mysqld.service --no-pager -n 50 | tee -a "$LOGFILE"
        tail -50 /var/log/mysqld.log 2>/dev/null | tee -a "$LOGFILE"
        fatal "MySQL service failed to start. Check logs above."
    fi

    # Enable MySQL service
    systemctl enable mysqld || warn "Failed to enable mysqld service"
    add_rollback_action "systemctl disable mysqld; systemctl stop mysqld || true"

    # Wait for MySQL to be ready
    info "Waiting for MySQL to become ready..."
    local max_wait=60
    local waited=0
    local mysql_ready=false
    
    while (( waited < max_wait )); do
        if systemctl is-active --quiet mysqld; then
            # Check if we can connect
            if mysqladmin ping -h localhost --silent 2>/dev/null; then
                mysql_ready=true
                info "MySQL is running and accepting connections"
                break
            fi
            
            # Check if socket exists
            if [[ -S /var/lib/mysql/mysql.sock ]]; then
                if mysql -u root -e "SELECT 1;" &>/dev/null 2>&1; then
                    mysql_ready=true
                    info "MySQL is ready"
                    break
                fi
            fi
        fi
        
        sleep 2
        ((waited += 2))
        
        # Show progress every 10 seconds
        if (( waited % 10 == 0 )); then
            info "Still waiting for MySQL... ($waited/$max_wait seconds)"
        fi
    done
    
    if [[ $mysql_ready == false ]]; then
        warn "MySQL did not become ready in time – checking status..."
        systemctl status mysqld --no-pager | tee -a "$LOGFILE"
        journalctl -xeu mysqld.service --no-pager -n 50 | tee -a "$LOGFILE"
        fatal "MySQL failed to start or is not responding after ${max_wait}s"
    fi

    # Set root password - IMPROVED METHOD
    info "Configuring MySQL root password..."
    
    # Method 1: Try password-less login (fresh install)
    if mysql -u root -e "SELECT 1;" &>/dev/null 2>&1; then
        info "Root password is currently empty – setting it now"
        
        # Use SQL directly instead of mysqladmin
        if mysql -u root <<EOSQL
ALTER USER 'root'@'localhost' IDENTIFIED BY '$MYPASS';
FLUSH PRIVILEGES;
EOSQL
        then
            info "MySQL root password set successfully via SQL"
        else
            fatal "Failed to set MySQL root password"
        fi
        
    # Method 2: Check if supplied password already works
    elif mysql -u root -p"$MYPASS" -e "SELECT 1;" &>/dev/null 2>&1; then
        info "Root password already matches supplied password"
        
    # Method 3: Password exists but doesn't match - need to reset
    else
        warn "Root password exists but doesn't match – resetting via skip-grant-tables..."
        
        # Stop MySQL cleanly
        info "Stopping MySQL service..."
        systemctl stop mysqld || true
        sleep 3
        
        # Kill any remaining processes
        pkill -9 mysqld 2>/dev/null || true
        sleep 2
        
        # Remove socket files
        rm -f /var/lib/mysql/mysql.sock /var/lib/mysql/mysql.sock.lock
        
        # Start MySQL in safe mode (skip-grant-tables)
        info "Starting MySQL in safe mode..."
        mysqld_safe --skip-grant-tables --skip-networking &
        local safe_pid=$!
        
        # Wait for socket to appear
        local socket_wait=0
        while [[ ! -S /var/lib/mysql/mysql.sock ]] && (( socket_wait < 30 )); do
            sleep 1
            ((socket_wait++))
        done
        
        if [[ ! -S /var/lib/mysql/mysql.sock ]]; then
            kill $safe_pid 2>/dev/null || true
            fatal "MySQL socket did not appear in safe mode"
        fi
        
        info "MySQL safe mode started, resetting password..."
        sleep 3
        
        # Reset the password
        if mysql -u root <<EOSQL
FLUSH PRIVILEGES;
ALTER USER 'root'@'localhost' IDENTIFIED BY '$MYPASS';
FLUSH PRIVILEGES;
EOSQL
        then
            info "Password reset command executed"
        else
            warn "ALTER USER failed, trying UPDATE method..."
            mysql -u root <<EOSQL
FLUSH PRIVILEGES;
UPDATE mysql.user SET authentication_string=PASSWORD('$MYPASS') WHERE User='root' AND Host='localhost';
FLUSH PRIVILEGES;
EOSQL
        fi
        
        # Stop safe mode MySQL
        info "Stopping safe mode MySQL..."
        kill $safe_pid 2>/dev/null || true
        sleep 2
        pkill -9 mysqld 2>/dev/null || true
        sleep 2
        
        # Remove socket files again
        rm -f /var/lib/mysql/mysql.sock /var/lib/mysql/mysql.sock.lock
        
        # Start MySQL normally
        info "Starting MySQL service normally..."
        if ! systemctl start mysqld; then
            journalctl -xeu mysqld.service --no-pager -n 50 | tee -a "$LOGFILE"
            fatal "Failed to start MySQL after password reset"
        fi
        
        # Wait for it to be ready
        sleep 5
        local verify_wait=0
        while ! mysqladmin ping -h localhost --silent 2>/dev/null && (( verify_wait < 30 )); do
            sleep 1
            ((verify_wait++))
        done
        
        # Verify the password works
        if mysql -u root -p"$MYPASS" -e "SELECT 1;" &>/dev/null 2>&1; then
            info "MySQL root password reset successfully"
        else
            warn "Password verification failed, checking MySQL status..."
            systemctl status mysqld --no-pager | tee -a "$LOGFILE"
            mysql -u root -p"$MYPASS" -e "SELECT 1;" 2>&1 | tee -a "$LOGFILE"
            fatal "Failed to verify MySQL root password after reset"
        fi
    fi

    # Final verification
    info "Verifying MySQL connection..."
    if ! mysql -u root -p"$MYPASS" -e "SELECT VERSION();" 2>&1 | tee -a "$LOGFILE"; then
        fatal "Cannot connect to MySQL with supplied password"
    fi

    # SSH configuration
    if ! grep -q '^PermitRootLogin' /etc/ssh/sshd_config 2>/dev/null; then
        if [[ ! -f /etc/ssh/sshd_config.installer-backup ]]; then
            cp /etc/ssh/sshd_config /etc/ssh/sshd_config.installer-backup
            add_rollback_action "mv /etc/ssh/sshd_config.installer-backup /etc/ssh/sshd_config"
        fi
        cat >>/etc/ssh/sshd_config <<'EOF'
PermitRootLogin yes
PasswordAuthentication yes
PermitEmptyPasswords no
EOF
        systemctl reload sshd || true
    fi

    # MySQL tuning
    if ! grep -q 'innodb_rollback_on_timeout' /etc/my.cnf 2>/dev/null; then
        if [[ ! -f /etc/my.cnf.installer-backup ]]; then
            cp /etc/my.cnf /etc/my.cnf.installer-backup
            add_rollback_action "mv /etc/my.cnf.installer-backup /etc/my.cnf; systemctl restart mysqld"
        fi
        cat >>/etc/my.cnf <<'EOF'

innodb_rollback_on_timeout=1
innodb_lock_wait_timeout=600
max_connections=350
log-bin=mysql-bin
binlog-format = 'ROW'
EOF
        info "Restarting MySQL to apply configuration changes..."
        systemctl restart mysqld || fatal "Failed to restart MySQL after configuration"
        sleep 5
        
        # Verify MySQL is still running after restart
        if ! systemctl is-active --quiet mysqld; then
            fatal "MySQL stopped after configuration change"
        fi
        
        if ! mysql -u root -p"$MYPASS" -e "SELECT 1;" &>/dev/null; then
            fatal "Cannot connect to MySQL after configuration change"
        fi
    fi

    # Perl DB modules (best-effort)
    command -v cpan >/dev/null && yes | cpan -i DBI DBD::mysql >/dev/null 2>&1 || true

    # CloudStack database setup
    info "Setting up CloudStack databases..."
    if ! cloudstack-setup-databases "cloud:${MYPASS}@localhost" --deploy-as "root:${MYPASS}" 2>&1 | tee -a "$LOGFILE"; then
        warn "CloudStack database setup failed – checking MySQL status..."
        mysql -u root -p"$MYPASS" -e "SHOW DATABASES;" 2>&1 | tee -a "$LOGFILE"
        fatal "CloudStack database setup failed"
    fi
    add_rollback_action "mysql -u root -p'${MYPASS}' -e 'DROP DATABASE IF EXISTS cloud; DROP DATABASE IF EXISTS cloud_usage;' || true"

    # Sudoers tweak
    grep -qxF 'Defaults:cloud !requiretty' /etc/sudoers 2>/dev/null || echo 'Defaults:cloud !requiretty' >>/etc/sudoers

    # MySQL client config
    local mycnf="${HOME}/.my.cnf"
    if [[ ! -f "$mycnf" ]]; then
        cat >"$mycnf" <<EOF
[client]
user=root
password="${MYPASS}"
EOF
        chmod 600 "$mycnf"
        add_rollback_action "rm -f $mycnf"
    fi

    # Bash aliases
    if ! grep -q 'cloudstack_mysql' ~/.bashrc 2>/dev/null; then
        cat >>~/.bashrc <<EOF
alias cloudstack_mysql_cloud='mysql -u cloud -p"${MYPASS}" cloud'
alias cloudstack_mysql_root='mysql -u root -p"${MYPASS}" cloud'
EOF
    fi

    # CloudStack management setup
    info "Setting up CloudStack management server..."
    if ! cloudstack-setup-management 2>&1 | tee -a "$LOGFILE"; then
        fatal "CloudStack management setup failed"
    fi

    enable_service_with_rollback cloudstack-management
    
    info "CloudStack management installation completed successfully"
    sleep 5
}


# -----------------------------------------------------------------
# Install agent
# -----------------------------------------------------------------
install_agent() {
    info "Installing the CloudStack agent"

    package_install_retry "$PKG_MGR" java-17-openjdk-headless java-17-openjdk-devel.x86_64

    package_install_retry "$PKG_MGR" cloudstack-agent qemu-kvm libvirt

    safe_write_file /etc/libvirt/libvirtd.conf <<'EOF'
listen_tls = 0
listen_tcp = 1
tcp_port = "16509"
auth_tcp = "none"
mdns_adv = 0
EOF

    safe_write_file /etc/libvirt/qemu.conf <<'EOF'
vnc_listen="0.0.0.0"
EOF

    safe_write_file /etc/sysconfig/libvirtd <<'EOF'
#LIBVIRTD_ARGS=-l
EOF

    if [[ -f /etc/libvirt/libvirt.conf ]]; then
        if ! grep -q '^mode' /etc/libvirt/libvirt.conf 2>/dev/null; then
            cp /etc/libvirt/libvirt.conf /etc/libvirt/libvirt.conf.backup.$$
            add_rollback_action "mv /etc/libvirt/libvirt.conf.backup.$$ /etc/libvirt/libvirt.conf"
            echo 'mode = "legacy"' >>/etc/libvirt/libvirt.conf
        fi
    fi

    mkdir -p /etc/cloudstack/agent
    if ! grep -q 'guest.cpu.mode=host-passthrough' /etc/cloudstack/agent/agent.properties 2>/dev/null; then
        echo 'guest.cpu.mode=host-passthrough' >>/etc/cloudstack/agent/agent.properties
    fi

    modprobe -n kvm-intel >/dev/null && modprobe kvm-intel || true

    systemctl enable --now libvirtd || true
    add_rollback_action "systemctl disable libvirtd; systemctl stop libvirtd"

    if systemctl list-unit-files | grep -q '^virtqemud'; then
        systemctl unmask virtqemud.socket virtqemud-ro.socket virtqemud-admin.socket virtqemud || true
        systemctl enable --now virtqemud || true
        add_rollback_action "systemctl disable virtqemud; systemctl stop virtqemud"
    fi

    systemctl enable --now cloudstack-agent || true
    add_rollback_action "systemctl disable cloudstack-agent; systemctl stop cloudstack-agent"
}

# -----------------------------------------------------------------
# Initialize storage
# -----------------------------------------------------------------
initialize_storage() {
    info "Setting up the storage server"
    package_install_retry "$PKG_MGR" quota-rpc rpcbind

    safe_write_file /etc/sysconfig/rpc-rquotad <<'EOF'
RPCRQUOTADOPTS="-p 875"
EOF

    systemctl enable --now rpcbind || true
    systemctl enable --now rpc-rquotad || true
    add_rollback_action "systemctl disable rpcbind rpc-rquotad; systemctl stop rpcbind rpc-rquotad"

    [[ -z "$NFS_SERVER_PRIMARY" || -z "$NFS_SERVER_SECONDARY" || -z "$NETWORK" ]] && \
        fatal "NFS export paths or network not defined – aborting."

    mkdir -p "$NFS_SERVER_PRIMARY" "$NFS_SERVER_SECONDARY" /mnt/primary /mnt/secondary || true
    add_rollback_action "rmdir $NFS_SERVER_PRIMARY $NFS_SERVER_SECONDARY /mnt/primary /mnt/secondary 2>/dev/null || true"

    safe_write_file /etc/exports <<EOF
$NFS_SERVER_PRIMARY $NETWORK(rw,async,no_root_squash,no_subtree_check)
$NFS_SERVER_SECONDARY $NETWORK(rw,async,no_root_squash,no_subtree_check)
EOF

    exportfs -a || true
    add_rollback_action "exportfs -ua || true"

    # Mount and verify NFS shares
    verify_nfs_mount /mnt/primary "$NFS_SERVER_IP" "$NFS_SERVER_PRIMARY"
    add_rollback_action "umount /mnt/primary 2>/dev/null || true"
    
    sleep 3
    
    verify_nfs_mount /mnt/secondary "$NFS_SERVER_IP" "$NFS_SERVER_SECONDARY"
    add_rollback_action "umount /mnt/secondary 2>/dev/null || true"

    rm -rf /mnt/primary/* /mnt/secondary/* 2>/dev/null || true

    if [[ -n "$VERs" && -n "$VER" ]]; then
        local base="http://download.cloudstack.org/systemvm/4.20"
        local templates=(
            "systemvmtemplate-$VER-x86_64-hyperv.vhd.zip:hyperv"
            "systemvmtemplate-$VER-x86_64-xen.vhd.bz2:xenserver"
            "systemvmtemplate-$VER-x86_64-vmware.ova:vmware"
            "systemvmtemplate-$VER-x86_64-kvm.qcow2.bz2:kvm"
            "systemvmtemplate-$VER-x86_64-ovm.raw.bz2:ovm3"
        )
        
        for template_info in "${templates[@]}"; do
            local template="${template_info%%:*}"
            local hypervisor="${template_info##*:}"
            
            info "Installing SystemVM template for $hypervisor..."
            retry_command "$MAX_RETRIES" \
                /usr/share/cloudstack-common/scripts/storage/secondary/cloud-install-sys-tmplt \
                -m "$NFS_SERVER_SECONDARY" -u "$base/$template" -h "$hypervisor" -F || warn "Failed to install $hypervisor template"
        done
    else
        warn "VER/VERs not set – skipping SystemVM template download."
    fi
}

# -----------------------------------------------------------------
# Install NFS server (SIMPLER FIX – individual rollback actions)
# -----------------------------------------------------------------
install_nfs() {
    info "Installing NFS server and configuring firewall"
    safe_write_file /etc/nfs.conf <<'EOF'
[general]
[exportfs]
[gssd]
use-gss-proxy=1
[lockd]
port=32803
udp-port=32769
[mountd]
port=892
[nfsdcld]
[nfsdcltrack]
[nfsd]
[statd]
port=662
outgoing-port=2020
[sm-notify]
EOF

    enable_service_with_rollback nfs-server

    local ports=(
        111/tcp 2049/tcp 32803/tcp 32769/udp 892/tcp 892/udp
        875/tcp 875/udp 10000/tcp 8080/tcp 662/tcp 8250/tcp
        8443/tcp 9090/tcp 8080/udp 8250/udp 8443/udp 9090/udp
        22/tcp 3306/tcp 1798/tcp 16514/tcp 5900-6100/tcp 49152-49216/tcp
    )
    
    local needs_reload=false
    
    for p in "${ports[@]}"; do
        if ! firewall-cmd --query-port="$p" --permanent &>/dev/null; then
            if firewall-cmd --zone=public --add-port="$p" --permanent; then
                needs_reload=true
                info "Added firewall port: $p"
                # Add individual rollback action for each port
                add_rollback_action "firewall-cmd --zone=public --remove-port='$p' --permanent 2>/dev/null || true"
            fi
        else
            info "Firewall port already open: $p"
        fi
    done
    
    if [[ $needs_reload == true ]]; then
        firewall-cmd --reload || true
        info "Firewall rules reloaded"
        # Add reload to rollback
        add_rollback_action "firewall-cmd --reload 2>/dev/null || true"
    fi
}

# -----------------------------------------------------------------
# Uninstall function (ENHANCED with network restore)
# -----------------------------------------------------------------
uninstall_cloudstack() {
    warn "=== CloudStack Uninstallation ==="
    warn "This will remove CloudStack and related components."
    read -rp "Are you sure you want to uninstall? Type 'yes' to confirm: " confirm
    
    if [[ "$confirm" != "yes" ]]; then
        info "Uninstall cancelled."
        exit 0
    fi
    
    # Determine package manager
    if command -v dnf >/dev/null; then
        PKG_MGR=dnf
    else
        PKG_MGR=yum
    fi
    
    info "Stopping services..."
    systemctl stop cloudstack-management cloudstack-agent 2>/dev/null || true
    systemctl disable cloudstack-management cloudstack-agent 2>/dev/null || true
    
    info "Unmounting NFS shares..."
    umount /mnt/primary /mnt/secondary 2>/dev/null || true
    
    info "Removing packages..."
    $PKG_MGR remove -y cloudstack-management cloudstack-agent cloudstack-common 2>/dev/null || true
    
    info "Removing databases..."
    if systemctl is-active --quiet mysqld; then
        read -rsp "Enter MySQL root password: " mysql_pass
        echo
        mysql -u root -p"$mysql_pass" -e "DROP DATABASE IF EXISTS cloud; DROP DATABASE IF EXISTS cloud_usage;" 2>/dev/null || warn "Failed to drop databases"
    fi
    
    info "Removing configuration files..."
    rm -rf /etc/cloudstack 2>/dev/null || true
    rm -f /etc/yum.repos.d/CloudStack.repo 2>/dev/null || true
    
    # Restore network configuration
    info "Restoring network configuration..."
    restore_network_config
    
    read -rp "Remove MySQL server? (yes/no): " remove_mysql
    if [[ "$remove_mysql" == "yes" ]]; then
        systemctl stop mysqld 2>/dev/null || true
        systemctl disable mysqld 2>/dev/null || true
        $PKG_MGR remove -y mysql-server 2>/dev/null || true
        rm -rf /var/lib/mysql 2>/dev/null || true
    fi
    
    read -rp "Remove NFS server? (yes/no): " remove_nfs
    if [[ "$remove_nfs" == "yes" ]]; then
        systemctl stop nfs-server 2>/dev/null || true
        systemctl disable nfs-server 2>/dev/null || true
        $PKG_MGR remove -y nfs-utils 2>/dev/null || true
        rm -f /etc/exports 2>/dev/null || true
    fi
    
    # Restore backup files if they exist
    info "Restoring backup configuration files..."
    for backup in /etc/selinux/config.installer-backup \
                  /etc/ssh/sshd_config.installer-backup \
                  /etc/my.cnf.installer-backup \
                  /etc/hosts.installer-backup \
                  /etc/hostname.installer-backup; do
        if [[ -f "$backup" ]]; then
            original="${backup%.installer-backup}"
            mv "$backup" "$original"
            info "Restored: $original"
        fi
    done
    
    # Clean up backup directory
    rm -rf /var/lib/cloudstack-installer-backup 2>/dev/null || true
    
    info "Uninstallation complete!"
    info "Note: Network configuration has been restored to pre-installation state."
    info "You may need to reconnect if the IP address changed."
}

# -----------------------------------------------------------------
# Command-line option parsing
# -----------------------------------------------------------------
if [[ $# -eq 0 ]]; then
    OPT_ERROR=1
else
    OPT_ERROR=0
fi

while getopts "acnmhwru" flag; do
    case "$flag" in
        \?) OPT_ERROR=1; break ;;
        h)  OPT_ERROR=1; break ;;
        a)  opt_agent=true ;;
        c)  opt_common=true ;;
        n)  opt_nfs=true ;;
        m)  opt_management=true ;;
        w)  opt_webmin=true ;;
        r)  opt_reboot=true ;;
        u)  opt_uninstall=true ;;
    esac
done
shift $((OPTIND - 1))

if (( OPT_ERROR )); then
    cat >&2 <<'USAGE'
Usage: cloudstack-installer.sh [-acnmwru]   (-h for help)

  -c  Install common packages and basic configuration
  -n  Install NFS server (requires NFS info)
  -a  Install CloudStack agent
  -m  Install CloudStack management server (requires NFS info)
  -w  Install Webmin 
  -r  Reboot after successful installation
  -u  Uninstall CloudStack
  -h  Show this help
USAGE
    exit 1
fi

# -----------------------------------------------------------------
# Handle uninstall
# -----------------------------------------------------------------
if [[ "$opt_uninstall" == "true" ]]; then
    uninstall_cloudstack
    exit 0
fi

# -----------------------------------------------------------------
# Gather required input
# -----------------------------------------------------------------
if [[ "$opt_agent" == "true" || "$opt_common" == "true" || "$opt_management" == "true" ]]; then
    get_network_info
fi
if [[ "$opt_nfs" == "true" || "$opt_management" == "true" ]]; then
    get_nfs_network
fi
if [[ "$opt_management" == "true" ]]; then
    get_nfs_info
fi

# -----------------------------------------------------------------
# Execute requested actions
# -----------------------------------------------------------------
if [[ "$opt_common" == "true" ]]; then
    add_ssh_public_key
    install_common
fi
if [[ "$opt_agent" == "true" ]]; then
    install_agent
fi
if [[ "$opt_nfs" == "true" ]]; then
    install_nfs
fi
if [[ "$opt_management" == "true" ]]; then
    install_management
    initialize_storage
fi
if [[ "$opt_webmin" == "true" ]]; then
    install_webmin
fi

# -----------------------------------------------------------------
# Success - clear rollback actions
# -----------------------------------------------------------------
{
    echo "[$(date)] ========================================"
    echo "[$(date)] Installation completed successfully!"
    echo "[$(date)] Newly installed packages: ${NEWLY_INSTALLED_PACKAGES[*]}"
    echo "[$(date)] Log file: $LOGFILE"
    echo "[$(date)] ========================================"
} | tee -a "$LOGFILE" 2>/dev/null || cat >>"$LOGFILE"

ROLLBACK_ACTIONS=()  # Clear rollback actions on success

if [[ "$opt_reboot" == "true" ]]; then
    sync; sync; sync
    info "Rebooting now…"
    reboot || true
fi

info "Script finished successfully."
