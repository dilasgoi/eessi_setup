#!/bin/bash
#==============================================================================
# EESSI Client Configuration Script
#==============================================================================
# Author:      Diego Lasa
# Description: Installs and configures EESSI client with proper error handling
#              and support for local Stratum 1 server
# Usage:       sudo ./eessi_client_setup.sh
#              
# Environment: EESSI_STRATUM1_IP  - IP address of local Stratum 1 server
#              EESSI_CACHE_SIZE   - CVMFS cache size in MB (default: 10000)
#              EESSI_LOG_FILE     - Path to log file
#              EESSI_CACHE_BASE   - Custom location for CVMFS cache
#                                  (default: /var/lib/cvmfs)
#
# Example:     EESSI_STRATUM1_IP=10.1.12.5 EESSI_CACHE_SIZE=20000 \
#              sudo -E ./eessi_client_setup.sh
#
# Notes:       This script supports RHEL/CentOS/Rocky/Fedora and Debian/Ubuntu
#              Based on EESSI documentation: https://www.eessi.io/docs/
#==============================================================================

# Strict mode
set -e  # Exit immediately if a command exits with a non-zero status
set -u  # Treat unset variables as an error

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
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] $message" | tee -a "$LOG_FILE"
}

# Check if command succeeded
check_success() {
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
        log "ERROR: Unsupported package manager"
        exit 1
    fi
}

# Function to verify connectivity with Stratum 1
check_stratum1_connectivity() {
    local stratum1_ip="$1"
    log "Verifying connectivity to Stratum 1 server: $stratum1_ip"
    
    # Try ping first (quick check)
    if ping -c 1 -W 2 "$stratum1_ip" > /dev/null 2>&1; then
        log "SUCCESS: Stratum 1 server is reachable via ping"
        
        # Check HTTP connectivity
        if curl -s --head --connect-timeout 5 "http://$stratum1_ip" > /dev/null 2>&1; then
            log "SUCCESS: Stratum 1 server is reachable via HTTP"
            return 0
        else
            log "WARNING: Stratum 1 server is reachable via ping but not via HTTP"
            log "Please verify that HTTP service is running on Stratum 1 server"
            return 1
        fi
    else
        log "WARNING: Cannot ping Stratum 1 server at $stratum1_ip"
        log "Connectivity issues may affect CVMFS operation"
        return 1
    fi
}

#------------------------------------------------------------------------------
# Helper functions for main steps
#------------------------------------------------------------------------------

# Initialize logging
initialize_logging() {
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    touch "$LOG_FILE" 2>/dev/null || {
        LOG_FILE="./eessi_client_install.log"
        touch "$LOG_FILE"
        log "WARNING: Could not create log in /var/log, using $LOG_FILE instead"
    }

    log "Starting EESSI client installation and configuration"
    log "Using configuration:"
    log "- Stratum 1 Server: $STRATUM1_IP (override with EESSI_STRATUM1_IP)"
    log "- CVMFS Cache Size: $CVMFS_CACHE_SIZE MB (override with EESSI_CACHE_SIZE)"
    log "- CVMFS Cache Base: $CVMFS_CACHE_BASE (override with EESSI_CACHE_BASE)"
    log "- Log File: $LOG_FILE (override with EESSI_LOG_FILE)"
}

# Check connectivity to Stratum 1 server
check_connectivity() {
    check_stratum1_connectivity "$STRATUM1_IP"
    if [ $? -ne 0 ]; then
        log "WARNING: Connectivity issues with Stratum 1 server detected"
        log "Installation will continue, but CVMFS may use fallback servers"
        log "If this is intentional, press Enter to continue or Ctrl+C to abort"
        read -r
    fi
}

# Detect and setup package manager
detect_package_manager() {
    if [ -f /usr/bin/dnf ]; then
        PKG_MANAGER="dnf"
    elif [ -f /usr/bin/yum ]; then
        PKG_MANAGER="yum"
    elif [ -f /usr/bin/apt ]; then
        PKG_MANAGER="apt"
        # Update apt cache
        log "Updating apt cache..."
        apt update -qq
        check_success "Apt cache update"
    else
        log "ERROR: Unsupported package manager. This script supports dnf, yum, and apt."
        exit 1
    fi

    log "Detected package manager: $PKG_MANAGER"
}

# Install CVMFS and EESSI configuration
install_packages() {
    if [ "$PKG_MANAGER" = "dnf" ] || [ "$PKG_MANAGER" = "yum" ]; then
        # RHEL-based distros installation
        
        # Install CVMFS if not already installed
        if ! is_package_installed "cvmfs"; then
            log "Installing CVMFS release RPM..."
            sudo $PKG_MANAGER install -y https://ecsft.cern.ch/dist/cvmfs/cvmfs-release/cvmfs-release-latest.noarch.rpm
            check_success "CVMFS release RPM installation"
            
            log "Installing CVMFS package..."
            sudo $PKG_MANAGER install -y cvmfs
            check_success "CVMFS package installation"
        else
            log "CVMFS is already installed"
        fi
        
        # Install EESSI configuration for CVMFS if not already installed
        if ! is_package_installed "cvmfs-config-eessi"; then
            log "Installing EESSI configuration RPM..."
            sudo $PKG_MANAGER install -y https://github.com/EESSI/filesystem-layer/releases/download/latest/cvmfs-config-eessi-latest.noarch.rpm
            check_success "EESSI configuration RPM installation"
        else
            log "EESSI configuration is already installed"
        fi
        
    elif [ "$PKG_MANAGER" = "apt" ]; then
        # Debian-based distros installation
        
        # Install dependencies
        log "Installing dependencies..."
        sudo apt install -y wget gnupg
        check_success "Dependencies installation"
        
        # Install CVMFS if not already installed
        if ! is_package_installed "cvmfs"; then
            log "Adding CVMFS repository..."
            wget -q https://ecsft.cern.ch/dist/cvmfs/cvmfs-release/debian/cvmfs-release-latest_all.deb
            sudo dpkg -i cvmfs-release-latest_all.deb
            rm -f cvmfs-release-latest_all.deb
            sudo apt update -qq
            
            log "Installing CVMFS package..."
            sudo apt install -y cvmfs
            check_success "CVMFS package installation"
        else
            log "CVMFS is already installed"
        fi
        
        # Install EESSI configuration for CVMFS if not already installed
        if ! is_package_installed "cvmfs-config-eessi"; then
            log "Installing EESSI configuration package..."
            wget -q https://github.com/EESSI/filesystem-layer/releases/download/latest/cvmfs-config-eessi-latest_all.deb
            sudo dpkg -i cvmfs-config-eessi-latest_all.deb
            rm -f cvmfs-config-eessi-latest_all.deb
            check_success "EESSI configuration package installation"
        else
            log "EESSI configuration is already installed"
        fi
    fi
}

# Configure CVMFS for EESSI
configure_cvmfs() {
    # Ensure configuration directory exists
    if [ ! -d /etc/cvmfs ]; then
        log "Creating CVMFS configuration directory..."
        sudo mkdir -p /etc/cvmfs
        check_success "CVMFS configuration directory creation"
    fi

    # Create default.local configuration file
    log "Creating default.local configuration file..."
    cat << EOF | sudo tee /etc/cvmfs/default.local > /dev/null
# CVMFS client configuration
# Generated by EESSI client configuration script

# Client profile (single for standalone, shared for shared cache/proxies)
CVMFS_CLIENT_PROFILE="single"

# Cache size limit in MB
CVMFS_QUOTA_LIMIT=$CVMFS_CACHE_SIZE

# Custom cache location (if specified)
CVMFS_CACHE_BASE=$CVMFS_CACHE_BASE

# Server configuration for local Stratum 1
CVMFS_SERVER_URL="http://$STRATUM1_IP/cvmfs/@fqrn@"
CVMFS_HTTP_PROXY="DIRECT"
EOF
    check_success "Configuration file creation"

    # Configure domain.d for EESSI
    log "Configuring EESSI domain..."
    if [ ! -d /etc/cvmfs/domain.d ]; then
        sudo mkdir -p /etc/cvmfs/domain.d
        check_success "CVMFS domain directory creation"
    fi

    # Create domain configuration file for EESSI with local Stratum 1
    # Note: We follow the recommended approach to use a .local file to override the default configuration
    log "Creating EESSI domain local configuration..."
    cat << EOF | sudo tee /etc/cvmfs/domain.d/eessi.io.local > /dev/null
# EESSI domain configuration pointing to local Stratum 1
# Primary server is local Stratum 1, with fallback to public mirrors
CVMFS_SERVER_URL="http://$STRATUM1_IP/cvmfs/@fqrn@;\$CVMFS_SERVER_URL"

# Disable GEO API to always prioritize local Stratum 1
CVMFS_USE_GEOAPI=no
EOF
    check_success "EESSI domain local configuration"
}

# Setup and validate CVMFS
setup_and_validate() {
    # Setup CVMFS
    log "Setting up CVMFS..."
    sudo cvmfs_config setup
    check_success "CVMFS setup"

    # Validate EESSI repository access
    log "Testing EESSI repository access..."
    if sudo cvmfs_config probe cvmfs-config.eessi.io; then
        log "EESSI configuration repository is accessible"
        
        if sudo cvmfs_config probe software.eessi.io; then
            log "EESSI software repository is accessible"
            
            # Verify repository content
            log "Verifying EESSI software repository content..."
            if ls /cvmfs/software.eessi.io &>/dev/null; then
                versions=$(ls /cvmfs/software.eessi.io 2>/dev/null | grep -v README)
                if [ -n "$versions" ]; then
                    log "SUCCESS: EESSI software repository is properly mounted"
                    log "Available EESSI versions:"
                    for version in $versions; do
                        log "- $version"
                    done
                    
                    # Check which server is actually being used (from diagnostics script)
                    log "Checking which server is actually being used..."
                    HOST_INFO=$(cvmfs_talk -i software.eessi.io host info 2>/dev/null)
                    if [ $? -eq 0 ]; then
                        log "Host information: "
                        echo "$HOST_INFO" | grep -E "Active host|Load-balance"
                        
                        if [[ "$HOST_INFO" == *"$STRATUM1_IP"* ]]; then
                            log "SUCCESS: Local Stratum 1 ($STRATUM1_IP) is being used"
                        else
                            log "WARNING: Local Stratum 1 ($STRATUM1_IP) is not being used"
                            log "Check your configuration if this is not intended"
                        fi
                    fi
                else
                    log "WARNING: EESSI software repository appears empty"
                fi
            else
                log "WARNING: Could not list EESSI repository content"
            fi
        else
            log "WARNING: Could not access EESSI software repository"
        fi
    else
        log "WARNING: Could not access EESSI configuration repository"
        log "Check your network connection and Stratum 1 server availability"
    fi
}

# Check disk space
check_disk_space() {
    cache_partition=$(df -P "$CVMFS_CACHE_BASE" | awk 'NR==2 {print $1}')
    cache_available=$(df -P "$CVMFS_CACHE_BASE" | awk 'NR==2 {print $4}')
    cache_available_gb=$(echo "scale=2; $cache_available/1024/1024" | bc)
    cache_size_gb=$(echo "scale=2; $CVMFS_CACHE_SIZE/1024" | bc)

    log "Checking disk space for CVMFS cache:"
    log "- Cache location: $CVMFS_CACHE_BASE"
    log "- Partition: $cache_partition"
    log "- Available space: ${cache_available_gb}GB"
    log "- Configured cache size: ${cache_size_gb}GB"

    if (( $(echo "$cache_available_gb < $cache_size_gb" | bc -l) )); then
        log "WARNING: Available disk space (${cache_available_gb}GB) is less than configured cache size (${cache_size_gb}GB)"
        log "Consider setting a smaller cache size or using a different partition with more space"
        log "You can set EESSI_CACHE_SIZE or EESSI_CACHE_BASE environment variables to adjust these settings"
    else
        log "Sufficient disk space available for CVMFS cache"
    fi
}

# Verify configuration
verify_configuration() {
    log "Verifying final configuration..."
    if cvmfs_config showconfig software.eessi.io | grep -q "CVMFS_SERVER_URL"; then
        SERVER_URL=$(cvmfs_config showconfig software.eessi.io | grep "CVMFS_SERVER_URL")
        log "Server URL configuration: $SERVER_URL"
        
        if [[ "$SERVER_URL" == *"$STRATUM1_IP"* ]]; then
            log "SUCCESS: Local Stratum 1 is properly configured"
        else
            log "WARNING: Local Stratum 1 is not in server URL configuration"
            log "You might need to reload the configuration:"
            log "  sudo cvmfs_config reload software.eessi.io"
        fi
    else
        log "WARNING: Could not verify CVMFS_SERVER_URL configuration"
    fi
}

# Print final summary
print_summary() {
    log "EESSI client installation and configuration completed"

    echo ""
    echo "======================================================"
    echo "EESSI Client Installation Summary"
    echo "======================================================"
    echo "Local Stratum 1 server: $STRATUM1_IP"
    echo "CVMFS cache size: $CVMFS_CACHE_SIZE MB"
    echo "CVMFS cache location: $CVMFS_CACHE_BASE"
    echo "Log file: $LOG_FILE"
    echo ""
    echo "If you experience any issues with the installation:"
    echo "  1. Check the log file: $LOG_FILE"
    echo "  2. Test repository access: sudo cvmfs_config probe software.eessi.io"
    echo "  3. Reload config if needed: sudo cvmfs_config reload software.eessi.io"
    echo "  4. Check active server: cvmfs_talk -i software.eessi.io host info"
    echo "  5. Check cache status: cvmfs_talk -i software.eessi.io cache info"
    echo ""
    echo "To use EESSI software, run:"
    echo "  source /cvmfs/software.eessi.io/versions/<version>/init/bash"
    echo "where <version> is your desired EESSI version"
    echo "======================================================"
}

#------------------------------------------------------------------------------
# Main function
#------------------------------------------------------------------------------
main() {
    initialize_logging
    check_connectivity
    detect_package_manager
    install_packages
    configure_cvmfs
    setup_and_validate
    check_disk_space
    verify_configuration
    print_summary
    log "Script execution completed successfully" "SUCCESS"
}

# Run the main function with all arguments
main "$@"
