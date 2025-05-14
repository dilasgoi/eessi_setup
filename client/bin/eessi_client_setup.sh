#!/bin/bash
#==============================================================================
# EESSI Client Configuration Script
#==============================================================================
# Author:       Diego Lasa
# Description: Installs and configures EESSI client with proper error handling
#              and support for local Stratum 1 server, focusing on software.eessi.io.
# Usage:        sudo ./eessi_client_setup.sh
#
# Environment: EESSI_STRATUM1_IP  - IP address of local Stratum 1 server
#              EESSI_CACHE_SIZE   - CVMFS cache size in MB (default: 10000)
#              EESSI_LOG_FILE     - Path to log file
#              EESSI_CACHE_BASE   - Custom location for CVMFS cache
#                                 (default: /var/lib/cvmfs)
#
# Example:      EESSI_STRATUM1_IP=10.1.12.5 EESSI_CACHE_SIZE=20000 \
#               sudo -E ./eessi_client_setup.sh
#
# Notes:        This script supports RHEL/CentOS/Rocky/Fedora and Debian/Ubuntu
#               Based on EESSI documentation: https://www.eessi.io/docs/
#==============================================================================

# Strict mode
set -e # Exit immediately if a command exits with a non-zero status
set -u # Treat unset variables as an error

#------------------------------------------------------------------------------
# Configuration variables (can be overridden with environment variables)
#------------------------------------------------------------------------------
# Default values
DEFAULT_STRATUM1_IP="10.1.12.2"     # Default IP address of local Stratum 1 server
DEFAULT_CVMFS_CACHE_SIZE="10000"    # Default cache size in MB (10GB)
DEFAULT_LOG_FILE="/var/log/eessi_client_install.log"
DEFAULT_CACHE_BASE="/var/lib/cvmfs" # Default CVMFS cache location

# Override from environment if provided
STRATUM1_IP="${EESSI_STRATUM1_IP:-$DEFAULT_STRATUM1_IP}"
CVMFS_CACHE_SIZE="${EESSI_CACHE_SIZE:-$DEFAULT_CVMFS_CACHE_SIZE}"
LOG_FILE="${EESSI_LOG_FILE:-$DEFAULT_LOG_FILE}"
CVMFS_CACHE_BASE="${EESSI_CACHE_BASE:-$DEFAULT_CACHE_BASE}"

#------------------------------------------------------------------------------
# Helper functions
#------------------------------------------------------------------------------
# Log messages with timestamp
log() {
    local message="$1"
    local timestamp
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] $message" | tee -a "$LOG_FILE"
}

# Check if command succeeded
check_success() {
    # shellcheck disable=SC2181
    if [ $? -eq 0 ]; then
        log "SUCCESS: $1"
    else
        log "ERROR: $1 failed with exit code $?"
        exit 1
    fi
}

# Check if package is installed
is_package_installed() {
    if [ -f /usr/bin/rpm ]; then
        rpm -q "$1" &>/dev/null
        return $?
    elif [ -f /usr/bin/dpkg ]; then
        dpkg -l "$1" 2>/dev/null | grep -q "^ii"
        return $?
    else
        log "ERROR: Unsupported package manager for package check: $1"
        return 1 
    fi
}

# Function to verify connectivity with Stratum 1
check_stratum1_connectivity() {
    local stratum1_ip="$1"
    log "Verifying connectivity to Stratum 1 server: $stratum1_ip"

    if ping -c 1 -W 2 "$stratum1_ip" > /dev/null 2>&1; then
        log "SUCCESS: Stratum 1 server ($stratum1_ip) is reachable via ping."
        if curl -s --head --connect-timeout 5 "http://$stratum1_ip/cvmfs/software.eessi.io/.cvmfspublished" > /dev/null 2>&1; then
            log "SUCCESS: Stratum 1 server ($stratum1_ip) is serving CVMFS data for software.eessi.io via HTTP."
            return 0 # Success
        else
            log "WARNING: Stratum 1 server ($stratum1_ip) is reachable via ping but '.cvmfspublished' for software.eessi.io is not accessible via HTTP."
            log "           Please verify HTTP service and CVMFS repository setup on the Stratum 1 server."
            return 1 # Failure
        fi
    else
        log "WARNING: Cannot ping Stratum 1 server at $stratum1_ip."
        log "           Connectivity issues will prevent CVMFS operation with this server."
        return 1 # Failure
    fi
}

#------------------------------------------------------------------------------
# Main script logic
#------------------------------------------------------------------------------

initialize_logging() {
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    if ! touch "$LOG_FILE" 2>/dev/null; then
        TEMP_LOG_FILE="/tmp/eessi_client_install_$(date +%Y%m%d_%H%M%S)_$$.log"
        # shellcheck disable=SC2034 # LOG_FILE is used globally by log()
        LOG_FILE="$TEMP_LOG_FILE" 
        if ! touch "$LOG_FILE" 2>/dev/null; then
             echo "[$(date +"%Y-%m-%d %H:%M:%S")] FATAL: Cannot write to default log path, custom log path, or /tmp. Please check permissions. Exiting." >&2
             exit 1
        fi
        # Initial log message to the new file
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] WARNING: Original log path not writable. Using temporary log file: $LOG_FILE" | tee -a "$LOG_FILE"
    fi
    log "=== EESSI Client Setup Script Started ==="
    log "Using configuration:"
    log "- Stratum 1 Server: $STRATUM1_IP (Env: EESSI_STRATUM1_IP)"
    log "- CVMFS Cache Size: $CVMFS_CACHE_SIZE MB (Env: EESSI_CACHE_SIZE)"
    log "- CVMFS Cache Base: $CVMFS_CACHE_BASE (Env: EESSI_CACHE_BASE)"
    log "- Log File: $LOG_FILE (Env: EESSI_LOG_FILE)"
}

check_connectivity_interactive() {
    # check_stratum1_connectivity returns 0 on success, 1 on failure
    if ! check_stratum1_connectivity "$STRATUM1_IP"; then 
        log "CRITICAL WARNING: Connectivity issues with Stratum 1 server ($STRATUM1_IP) detected."
        log "CVMFS operation will likely fail if this server is the primary source."
        log "Press Enter to attempt installation anyway, or Ctrl+C to abort within 15 seconds."
        # Read into a dummy variable to satisfy set -u if input is empty on timeout
        local user_ack=""
        if ! read -t 15 -r user_ack; then
            log "No input received within 15 seconds. Proceeding with installation attempt despite connectivity warnings."
        else
            log "User acknowledged connectivity warnings. Proceeding with installation attempt."
        fi
    else
        log "Connectivity to Stratum 1 server $STRATUM1_IP looks good."
    fi
}

detect_package_manager() {
    if command -v dnf &> /dev/null; then
        PKG_MANAGER="dnf"
    elif command -v yum &> /dev/null; then
        PKG_MANAGER="yum"
    elif command -v apt-get &> /dev/null; then
        PKG_MANAGER="apt"
        log "Updating apt cache (sudo apt-get update -qq)..."
        if ! sudo apt-get update -qq; then
            log "WARNING: 'apt-get update' failed. Proceeding, but package installation might encounter issues."
        else
            check_success "Apt cache update" # check_success will exit if 'apt update' fails and set -e is on. The above handles it gracefully.
        fi
    else
        log "ERROR: Unsupported package manager. This script supports dnf, yum, and apt-get."
        exit 1
    fi
    log "Detected package manager: $PKG_MANAGER"
}

install_packages() {
    local cvmfs_pkg_name="cvmfs"
    local eessi_config_pkg_name="cvmfs-config-eessi"

    if [ "$PKG_MANAGER" = "dnf" ] || [ "$PKG_MANAGER" = "yum" ]; then
        if ! is_package_installed "$cvmfs_pkg_name"; then
            log "Installing CVMFS release RPM..."
            sudo "$PKG_MANAGER" install -y https://ecsft.cern.ch/dist/cvmfs/cvmfs-release/cvmfs-release-latest.noarch.rpm
            check_success "CVMFS release RPM installation"
            log "Installing $cvmfs_pkg_name package..."
            sudo "$PKG_MANAGER" install -y "$cvmfs_pkg_name"
            check_success "$cvmfs_pkg_name package installation"
        else
            log "$cvmfs_pkg_name is already installed."
        fi
        if ! is_package_installed "$eessi_config_pkg_name"; then
            log "Installing $eessi_config_pkg_name RPM..."
            sudo "$PKG_MANAGER" install -y https://github.com/EESSI/filesystem-layer/releases/download/latest/cvmfs-config-eessi-latest.noarch.rpm
            check_success "$eessi_config_pkg_name RPM installation"
        else
            log "$eessi_config_pkg_name is already installed."
        fi
    elif [ "$PKG_MANAGER" = "apt" ]; then
        log "Installing dependencies (wget, gnupg) for Debian/Ubuntu..."
        sudo apt-get install -y wget gnupg
        check_success "Dependencies installation (wget, gnupg)"
        if ! is_package_installed "$cvmfs_pkg_name"; then
            log "Downloading CVMFS release .deb..."
            wget -qO cvmfs-release-latest_all.deb https://ecsft.cern.ch/dist/cvmfs/cvmfs-release/debian/cvmfs-release-latest_all.deb
            check_success "Download CVMFS release .deb"
            sudo dpkg -i cvmfs-release-latest_all.deb
            check_success "Install CVMFS release .deb"
            rm -f cvmfs-release-latest_all.deb
            log "Updating apt cache after adding CVMFS repo..."
            if ! sudo apt-get update -qq; then log "WARNING: 'apt-get update' post CVMFS repo add failed."; else check_success "Apt cache update post CVMFS repo"; fi
            log "Installing $cvmfs_pkg_name package..."
            sudo apt-get install -y "$cvmfs_pkg_name"
            check_success "$cvmfs_pkg_name package installation"
        else
            log "$cvmfs_pkg_name is already installed."
        fi
        if ! is_package_installed "$eessi_config_pkg_name"; then
            log "Downloading $eessi_config_pkg_name .deb..."
            wget -qO cvmfs-config-eessi-latest_all.deb https://github.com/EESSI/filesystem-layer/releases/download/latest/cvmfs-config-eessi-latest_all.deb
            check_success "Download $eessi_config_pkg_name .deb"
            sudo dpkg -i cvmfs-config-eessi-latest_all.deb
            check_success "Install $eessi_config_pkg_name .deb"
            rm -f cvmfs-config-eessi-latest_all.deb
        else
            log "$eessi_config_pkg_name is already installed."
        fi
    fi
}

configure_cvmfs() {
    local TMP_CONFIG_FILE
    TMP_CONFIG_FILE=$(mktemp /tmp/cvmfs_config.XXXXXX) # Create temp file once

    if [ ! -d /etc/cvmfs ]; then log "Creating CVMFS config dir (/etc/cvmfs)..."; sudo mkdir -p /etc/cvmfs; check_success "Create /etc/cvmfs"; fi
    
    log "Writing /etc/cvmfs/default.local..."
    cat << EOF > "$TMP_CONFIG_FILE"
# CVMFS client configuration - Generated by EESSI script $(date)
CVMFS_CLIENT_PROFILE="single"
CVMFS_QUOTA_LIMIT=$CVMFS_CACHE_SIZE
CVMFS_CACHE_BASE=$CVMFS_CACHE_BASE
CVMFS_SERVER_URL="http://$STRATUM1_IP/cvmfs/@fqrn@" 
CVMFS_HTTP_PROXY="DIRECT"
CVMFS_REPOSITORIES="software.eessi.io"
EOF
    sudo cp "$TMP_CONFIG_FILE" /etc/cvmfs/default.local && sudo chown root:root /etc/cvmfs/default.local && sudo chmod 644 /etc/cvmfs/default.local
    check_success "Create/Update /etc/cvmfs/default.local"

    if [ ! -d /etc/cvmfs/domain.d ]; then log "Creating CVMFS domain dir (/etc/cvmfs/domain.d)..."; sudo mkdir -p /etc/cvmfs/domain.d; check_success "Create /etc/cvmfs/domain.d"; fi

    log "Writing /etc/cvmfs/domain.d/eessi.io.local for EESSI domain..."
    # This file affects all repositories under eessi.io, including software.eessi.io
    cat << EOF > "$TMP_CONFIG_FILE"
# EESSI domain configuration for eessi.io - Generated by EESSI script $(date)
# This ensures repositories under eessi.io use the local Stratum 1 primarily.
CVMFS_SERVER_URL="http://$STRATUM1_IP/cvmfs/@fqrn@;\$CVMFS_SERVER_URL"
CVMFS_USE_GEOAPI=no
EOF
    sudo cp "$TMP_CONFIG_FILE" /etc/cvmfs/domain.d/eessi.io.local 
    sudo chown root:root /etc/cvmfs/domain.d/eessi.io.local && sudo chmod 644 /etc/cvmfs/domain.d/eessi.io.local
    check_success "Create/Update /etc/cvmfs/domain.d/eessi.io.local"
    
    rm -f "$TMP_CONFIG_FILE" # Clean up temp file
}

setup_and_validate() {
    log "Running 'sudo cvmfs_config setup' to apply configurations and (re)start services..."
    sudo cvmfs_config setup
    check_success "CVMFS setup command execution"

    log "----------------------------------------------------------------------"
    log "Step: Critically validating EESSI software repository (software.eessi.io)"
    log "Attempting CVMFS probe for software.eessi.io..."
    if sudo cvmfs_config probe software.eessi.io; then
        log "SUCCESS: Probe of software.eessi.io was successful."
        log "This indicates CVMFS can contact the configured server for this repository."
        log "Now, attempting to list contents of /cvmfs/software.eessi.io to confirm active mount..."

        if sudo ls -A /cvmfs/software.eessi.io &>/dev/null; then
            log "DEBUG: Initial 'sudo ls -A /cvmfs/software.eessi.io' command was successful (directory is accessible)."
            
            local versions_output 
            local raw_ls_output   
            
            raw_ls_output=$(sudo ls -A /cvmfs/software.eessi.io 2>/dev/null || echo "__LS_CMD_FAILED__")
            
            if [[ "$raw_ls_output" == "__LS_CMD_FAILED__" ]]; then
                log "WARNING: Although initial 'ls' accessibility seemed to pass, the command 'sudo ls -A /cvmfs/software.eessi.io' failed when trying to capture its output."
                log "         This could indicate an intermittent issue or permissions problem for output capture."
                versions_output="" 
            else
                log "DEBUG: Raw directory listing of /cvmfs/software.eessi.io (before filtering README):"
                printf "%s\n" "$raw_ls_output" | sed 's/^/    /' | tee -a "$LOG_FILE"
                versions_output=$(echo "$raw_ls_output" | grep -v -E "^README$" || true)
            fi

            if [ -n "$versions_output" ]; then
                log "SUCCESS: EESSI software repository (/cvmfs/software.eessi.io) is mounted and contains version directories."
                log "Available EESSI versions (top level, excluding README):"
                echo "$versions_output" | while IFS= read -r version_item; do
                    if [ -n "$version_item" ]; then 
                        log "- $version_item"
                    fi
                done

                log "Checking which CVMFS server is actually being used for software.eessi.io via cvmfs_talk..."
                local HOST_INFO
                HOST_INFO=$(cvmfs_talk -i software.eessi.io host info 2>/dev/null || echo "__CVMFSTALK_CMD_FAILED__")
                
                if [[ "$HOST_INFO" == "__CVMFSTALK_CMD_FAILED__" ]] || ! echo "$HOST_INFO" | grep -q "Active host name"; then
                    log "WARNING: Could not retrieve valid host information from 'cvmfs_talk -i software.eessi.io host info'."
                    if [[ "$HOST_INFO" != "__CVMFSTALK_CMD_FAILED__" ]]; then 
                        log "DEBUG: cvmfs_talk output was:"
                        printf "%s\n" "$HOST_INFO" | sed 's/^/    /' | tee -a "$LOG_FILE"
                    fi
                else
                    log "Host information details from cvmfs_talk:"
                    printf "%s\n" "$HOST_INFO" | grep -E "Active host name|Load-balance group" | while IFS= read -r line; do log "  $line"; done

                    if echo "$HOST_INFO" | grep "Active host name" | grep -q "$STRATUM1_IP"; then
                        log "SUCCESS: Local Stratum 1 ($STRATUM1_IP) is confirmed as part of the active server string for software.eessi.io."
                    else
                        log "WARNING: Local Stratum 1 ($STRATUM1_IP) was NOT explicitly found in the 'Active host name' string."
                        log "         Actual active server details (from host info):"
                        printf "%s\n" "$HOST_INFO" | grep "Active host name" | sed 's/^/           /' | tee -a "$LOG_FILE"
                        log "         This could be normal if $STRATUM1_IP is part of a load-balanced group and another member is active,"
                        log "         or if GeoAPI is active and routing elsewhere (CVMFS_USE_GEOAPI=no in domain config should prevent this for $STRATUM1_IP)."
                        log "         If $STRATUM1_IP was intended to be the sole/primary active server, review CVMFS logs and configuration."
                    fi
                fi
            else 
                log "WARNING: 'sudo ls -A /cvmfs/software.eessi.io' was successful, but NO version directories were found (after excluding README)."
                log "         The EESSI repository might be empty on the server, or only contain a README file."
                log "         Review the raw directory listing (logged above if available) to confirm."
            fi
        else 
            log "CRITICAL WARNING: 'sudo ls -A /cvmfs/software.eessi.io' command FAILED or the directory is not accessible."
            log "                  This strongly indicates the CVMFS mount for software.eessi.io is NOT WORKING."
            log "                  Check CVMFS client logs (e.g., /var/log/cvmfs/*, journalctl) and system logs for errors related to FUSE or CVMFS."
        fi
    else 
        log "CRITICAL WARNING: Probe of EESSI software repository (software.eessi.io) FAILED."
        log "                  The EESSI software stack will LIKELY NOT be available or mount correctly."
        log "                  Common reasons for probe failure:"
        log "                  - Network connectivity issues to the Stratum 1 server ($STRATUM1_IP or fallback servers)."
        log "                  - The Stratum 1 server is down or not serving CVMFS data correctly for 'software.eessi.io'."
        log "                  - Incorrect CVMFS client configuration (e.g., wrong CVMFS_SERVER_URL, CVMFS_HTTP_PROXY issues)."
        log "                  - Firewall blocking CVMFS communication."
        log "                  - Problems with the CVMFS client services on this machine."
        log "                  Please verify these aspects and check CVMFS client logs."
    fi
    log "----------------------------------------------------------------------"
}

check_disk_space() {
    local cache_partition cache_available cache_available_gb cache_size_gb
    if [ ! -d "$CVMFS_CACHE_BASE" ]; then
        log "INFO: CVMFS cache base $CVMFS_CACHE_BASE does not exist. Attempting to create."
        sudo mkdir -p "$CVMFS_CACHE_BASE"
        check_success "Create $CVMFS_CACHE_BASE"
    fi

    cache_partition=$(df -P "$CVMFS_CACHE_BASE" 2>/dev/null | awk 'NR==2 {print $1}')
    cache_available=$(df -P "$CVMFS_CACHE_BASE" 2>/dev/null | awk 'NR==2 {print $4}')

    if [ -z "$cache_partition" ] || [ -z "$cache_available" ]; then
        log "WARNING: Could not determine disk space for $CVMFS_CACHE_BASE. Skipping detailed check."
        return
    fi

    if ! command -v bc &> /dev/null; then
        log "WARNING: 'bc' command not found. Skipping GB conversion for disk space. Available KB: $cache_available, Configured MB: $CVMFS_CACHE_SIZE"
        return
    fi
    
    cache_available_gb=$(echo "scale=2; $cache_available / 1024 / 1024" | bc)
    cache_size_gb=$(echo "scale=2; $CVMFS_CACHE_SIZE / 1024" | bc)

    log "Disk space check for CVMFS cache:"
    log "- Cache Location: $CVMFS_CACHE_BASE (on partition $cache_partition)"
    log "- Available Space: ${cache_available_gb} GB"
    log "- Configured Cache Size: ${cache_size_gb} GB"
    if (( $(echo "$cache_available_gb < $cache_size_gb" | bc -l) )); then
        log "WARNING: Available disk space (${cache_available_gb}GB) is LESS than configured cache size (${cache_size_gb}GB)."
    else
        log "Sufficient disk space available for CVMFS cache."
    fi
}

verify_final_configuration() {
    log "Verifying final effective CVMFS configuration for software.eessi.io..."
    local EFFECTIVE_CONFIG_FILE SERVER_URL REPOSITORIES_CONFIG
    EFFECTIVE_CONFIG_FILE=$(mktemp /tmp/cvmfs_effective_config.XXXXXX)

    if sudo cvmfs_config showconfig software.eessi.io > "$EFFECTIVE_CONFIG_FILE" 2>/dev/null; then
        if grep -q "CVMFS_SERVER_URL" "$EFFECTIVE_CONFIG_FILE"; then
            SERVER_URL=$(grep "CVMFS_SERVER_URL" "$EFFECTIVE_CONFIG_FILE")
            log "Effective Server URL (CVMFS_SERVER_URL): $SERVER_URL"
            if [[ "$SERVER_URL" == *"$STRATUM1_IP"* ]]; then
                log "SUCCESS: Local Stratum 1 ($STRATUM1_IP) is present in the effective CVMFS_SERVER_URL."
            else
                log "WARNING: Local Stratum 1 ($STRATUM1_IP) is NOT found in the effective CVMFS_SERVER_URL."
                log "         Actual URL: $SERVER_URL. Expected to contain: $STRATUM1_IP."
                log "         If using fallback servers, this might be normal. If $STRATUM1_IP should be primary, check config files and 'cvmfs_config reload'."
            fi
        else
            log "WARNING: CVMFS_SERVER_URL not found in effective configuration for software.eessi.io."
        fi

        if grep -q "CVMFS_REPOSITORIES" "$EFFECTIVE_CONFIG_FILE"; then
            REPOSITORIES_CONFIG=$(grep "CVMFS_REPOSITORIES" "$EFFECTIVE_CONFIG_FILE")
            log "Effective Repositories (CVMFS_REPOSITORIES): $REPOSITORIES_CONFIG"
            if [[ "$REPOSITORIES_CONFIG" == *"software.eessi.io"* ]]; then
                log "SUCCESS: 'software.eessi.io' is listed in effective CVMFS_REPOSITORIES."
            else
                log "WARNING: 'software.eessi.io' is NOT explicitly listed in effective CVMFS_REPOSITORIES."
            fi
        else
            log "INFO: CVMFS_REPOSITORIES not explicitly found in effective config. This is often okay as specific repositories are mounted on demand or via other configs."
        fi
        rm -f "$EFFECTIVE_CONFIG_FILE"
    else
        log "WARNING: Could not retrieve effective config using 'cvmfs_config showconfig software.eessi.io'."
        rm -f "$EFFECTIVE_CONFIG_FILE" 
    fi
}

print_summary() {
    log "EESSI client installation and configuration script finished."
    echo "" | tee -a "$LOG_FILE"
    echo "======================================================================" | tee -a "$LOG_FILE"
    echo " EESSI Client Setup Summary & Next Steps" | tee -a "$LOG_FILE"
    echo "======================================================================" | tee -a "$LOG_FILE"
    echo " Stratum 1 Server Used: $STRATUM1_IP" | tee -a "$LOG_FILE"
    echo " CVMFS Cache Size:      $CVMFS_CACHE_SIZE MB" | tee -a "$LOG_FILE"
    echo " CVMFS Cache Location:  $CVMFS_CACHE_BASE" | tee -a "$LOG_FILE"
    echo " Log File Location:     $LOG_FILE" | tee -a "$LOG_FILE"
    echo "----------------------------------------------------------------------" | tee -a "$LOG_FILE"
    echo " IMPORTANT: Review the FULL log file for any WARNINGS or ERRORS:" | tee -a "$LOG_FILE"
    echo "   $LOG_FILE" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
    echo " Post-Setup Checks & Troubleshooting:" | tee -a "$LOG_FILE"
    echo "   1. Check CVMFS mount:        ls -lA /cvmfs/software.eessi.io" | tee -a "$LOG_FILE"
    echo "   2. Test repository probe:    sudo cvmfs_config probe software.eessi.io" | tee -a "$LOG_FILE"
    echo "   3. Check active server:      cvmfs_talk -i software.eessi.io host info" | tee -a "$LOG_FILE"
    echo "   4. Check CVMFS client logs:  Look in /var/log/cvmfs/ or use journalctl." | tee -a "$LOG_FILE"
    echo "   5. If needed, reload CVMFS:  sudo cvmfs_config reload" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
    echo " To Use EESSI Software:" | tee -a "$LOG_FILE"
    echo "   Source an EESSI init script, e.g.:" | tee -a "$LOG_FILE"
    echo "     source /cvmfs/software.eessi.io/versions/<pilot_version>/init/bash" | tee -a "$LOG_FILE"
    echo "   (Replace <pilot_version> with an available version like '2023.06')" | tee -a "$LOG_FILE"
    echo "======================================================================" | tee -a "$LOG_FILE"
}

#------------------------------------------------------------------------------
# Main execution flow
#------------------------------------------------------------------------------
main() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "ERROR: This script must be run as root or with sudo." >&2
        exit 1
    fi

    initialize_logging
    check_connectivity_interactive
    detect_package_manager
    install_packages
    configure_cvmfs     
    setup_and_validate  
    check_disk_space
    verify_final_configuration
    print_summary
    log "=== EESSI Client Setup Script Completed ==="
}

# Pass all script arguments to the main function
main "$@"
