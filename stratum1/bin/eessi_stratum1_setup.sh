#!/bin/bash
#==============================================================================
# EESSI Stratum 1 Setup Script
#==============================================================================
# Author:      Diego Lasa
# Description: Sets up an EESSI Stratum 1 server using Ansible
#              following official EESSI documentation
# Usage:       sudo ./eessi_stratum1_setup.sh
#              
# Notes:       This script assumes you're running it on the server that will
#              become the Stratum 1, or from a machine that can SSH to it.
#==============================================================================

# Strict mode
set -e  # Exit immediately if a command exits with a non-zero status
set -u  # Treat unset variables as an error

#------------------------------------------------------------------------------
# Configuration variables (adjust as needed)
#------------------------------------------------------------------------------
# The server that will become the Stratum 1
STRATUM1_SERVER="localhost"
STRATUM1_SSH_USER="$(whoami)"

# Custom storage location (leave empty to use default /srv/cvmfs)
CUSTOM_STORAGE_DIR=""

# GeoAPI setup (yes/no) - for private Stratum 1 this can be "no"
USE_GEOAPI="no"

# Repository to replicate
REPOSITORY="software.eessi.io"

# Log file
LOG_FILE="/var/log/eessi_stratum1_setup.log"

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

#------------------------------------------------------------------------------
# Main execution starts here
#------------------------------------------------------------------------------
# Initialize log file
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
touch "$LOG_FILE" 2>/dev/null || {
    LOG_FILE="./eessi_stratum1_setup.log"
    touch "$LOG_FILE"
    log "WARNING: Could not create log in /var/log, using $LOG_FILE instead"
}

log "Starting EESSI Stratum 1 server setup"
log "Target server: $STRATUM1_SERVER"
log "SSH user: $STRATUM1_SSH_USER"
log "Repository to replicate: $REPOSITORY"

#------------------------------------------------------------------------------
# 1. Install Ansible
#------------------------------------------------------------------------------
if ! command -v ansible >/dev/null 2>&1; then
    log "Installing Ansible..."
    
    if [ -f /usr/bin/dnf ]; then
        sudo dnf install -y ansible
    elif [ -f /usr/bin/yum ]; then
        sudo yum install -y ansible
    elif [ -f /usr/bin/apt ]; then
        sudo apt update
        sudo apt install -y ansible
    else
        log "ERROR: Unsupported package manager. Please install Ansible manually."
        exit 1
    fi
    
    check_success "Ansible installation"
else
    log "Ansible is already installed"
fi

#------------------------------------------------------------------------------
# 2. Clone the EESSI filesystem-layer repository
#------------------------------------------------------------------------------
if [ ! -d "filesystem-layer" ]; then
    log "Cloning EESSI filesystem-layer repository..."
    git clone https://github.com/EESSI/filesystem-layer.git
    check_success "Repository cloning"
else
    log "EESSI filesystem-layer repository directory already exists"
    log "Updating repository..."
    ( cd filesystem-layer && git pull )
    check_success "Repository update"
fi

cd filesystem-layer
log "Working directory: $(pwd)"

#------------------------------------------------------------------------------
# 3. Install Ansible roles
#------------------------------------------------------------------------------
log "Installing required Ansible roles..."
ansible-galaxy role install -r ./requirements.yml --force
check_success "Ansible roles installation"

#------------------------------------------------------------------------------
# 4. Set up storage (if custom location specified)
#------------------------------------------------------------------------------
if [ -n "$CUSTOM_STORAGE_DIR" ]; then
    log "Setting up custom storage location: $CUSTOM_STORAGE_DIR"
    if [[ "$STRATUM1_SERVER" == "localhost" || "$STRATUM1_SERVER" == "127.0.0.1" ]]; then
        # Local setup
        sudo mkdir -p "$CUSTOM_STORAGE_DIR"
        sudo mkdir -p /srv
        log "Creating symlink from /srv/cvmfs to $CUSTOM_STORAGE_DIR"
        sudo ln -sf "$CUSTOM_STORAGE_DIR" /srv/cvmfs
    else
        # Remote setup
        log "NOTE: For remote servers, please ensure the following is done on the target server:"
        log "      1. Create directory: mkdir -p $CUSTOM_STORAGE_DIR"
        log "      2. Create symlink: ln -sf $CUSTOM_STORAGE_DIR /srv/cvmfs"
        log "Press Enter when this is done, or Ctrl+C to abort"
        read -r
    fi
    check_success "Storage setup"
fi

#------------------------------------------------------------------------------
# 5. Create hosts file
#------------------------------------------------------------------------------
log "Creating Ansible inventory hosts file..."
mkdir -p inventory
cat > inventory/hosts << EOF
[cvmfsstratum1servers]
$STRATUM1_SERVER ansible_ssh_user=$STRATUM1_SSH_USER
EOF
check_success "Hosts file creation"

#------------------------------------------------------------------------------
# 6. Modify all.yml to only include software.eessi.io
#------------------------------------------------------------------------------
if [ -f "inventory/group_vars/all.yml" ]; then
    log "Creating backup of all.yml..."
    cp "inventory/group_vars/all.yml" "inventory/group_vars/all.yml.bak"
    
    log "Modifying all.yml to only include $REPOSITORY..."
    # Extract the repository configuration sections
    mkdir -p inventory/group_vars
    
    # Use awk to keep only the specified repository
    awk -v repo="$REPOSITORY" '
    BEGIN { printing = 1; repo_found = 0; in_repos = 0; }
    /^eessi_cvmfs_repositories:/ { 
        print; 
        in_repos = 1; 
        next; 
    }
    in_repos && !repo_found && $0 ~ "repository: " repo { 
        repo_found = 1; 
        repo_block = $0 "\n"; 
        next; 
    }
    in_repos && repo_found && /^  - repository:/ { 
        # Hit the next repository, stop collecting this one
        print "  - " repo_block; 
        repo_block = ""; 
        in_repos = 0; 
    }
    in_repos && repo_found { 
        # Collecting lines for this repository
        repo_block = repo_block $0 "\n"; 
        next; 
    }
    in_repos && /^[^ -]/ { 
        # End of repositories section
        if (repo_found) print "  - " repo_block;
        in_repos = 0; 
        repo_found = 0; 
        print; 
        next; 
    }
    !in_repos { print; }
    END {
        if (in_repos && repo_found) print "  - " repo_block;
    }
    ' "inventory/group_vars/all.yml.bak" > "inventory/group_vars/all.yml.new"
    
    # Check if the new file has content
    if [ -s "inventory/group_vars/all.yml.new" ]; then
        mv "inventory/group_vars/all.yml.new" "inventory/group_vars/all.yml"
        check_success "Repository configuration modified"
    else
        log "WARNING: Failed to modify all.yml properly. Using original file."
    fi
else
    log "WARNING: all.yml not found. Please ensure repository configuration is correct."
fi

#------------------------------------------------------------------------------
# 7. Create local_site_specific_vars.yml for GeoAPI if needed
#------------------------------------------------------------------------------
if [ "$USE_GEOAPI" = "yes" ]; then
    log "Creating site-specific variables file for GeoAPI..."
    mkdir -p inventory
    cat > inventory/local_site_specific_vars.yml << EOF
---
# GeoAPI configuration for EESSI Stratum 1
# See: https://cvmfs.readthedocs.io/en/stable/cpt-replica.html#geo-api-setup

# You need to replace these values with your actual GeoAPI credentials
cvmfs_geo_license_key: FIXME
cvmfs_geo_account_id: FIXME
EOF
    check_success "GeoAPI configuration file creation"
    
    log "IMPORTANT: Edit inventory/local_site_specific_vars.yml to add your GeoAPI credentials"
    log "           See: https://cvmfs.readthedocs.io/en/stable/cpt-replica.html#geo-api-setup"
    log "Press Enter when done, or Ctrl+C to abort"
    read -r
fi

#------------------------------------------------------------------------------
# 8. Run the Ansible playbook
#------------------------------------------------------------------------------
log "Ready to run Ansible playbook to deploy Stratum 1 server"
log "This will install and configure EESSI Stratum 1 for $REPOSITORY"
log "Press Enter to continue or Ctrl+C to abort"
read -r

PLAYBOOK_CMD="ansible-playbook -b"

# Add -K if we're connecting to a remote server that may need password for sudo
if [[ "$STRATUM1_SERVER" != "localhost" && "$STRATUM1_SERVER" != "127.0.0.1" ]]; then
    PLAYBOOK_CMD="$PLAYBOOK_CMD -K"
fi

# Add vars file if GeoAPI is enabled
if [ "$USE_GEOAPI" = "yes" ]; then
    PLAYBOOK_CMD="$PLAYBOOK_CMD -e @inventory/local_site_specific_vars.yml"
fi

# Run the playbook
log "Running Ansible playbook: $PLAYBOOK_CMD stratum1.yml"
eval "$PLAYBOOK_CMD stratum1.yml"
check_success "Ansible playbook execution"

#------------------------------------------------------------------------------
# 9. Verify the installation
#------------------------------------------------------------------------------
log "Verifying Stratum 1 server installation..."

# Determine the hostname/IP to use for verification
if [[ "$STRATUM1_SERVER" == "localhost" || "$STRATUM1_SERVER" == "127.0.0.1" ]]; then
    # Use hostname if localhost
    VERIFY_HOST=$(hostname -f)
else
    VERIFY_HOST="$STRATUM1_SERVER"
fi

TEST_URL="http://$VERIFY_HOST/cvmfs/$REPOSITORY/.cvmfspublished"

log "Testing access to EESSI repository with: curl --head $TEST_URL"
if curl --head "$TEST_URL" &>/dev/null; then
    log "SUCCESS: EESSI repository is accessible!"
    log "Response headers:"
    curl --head "$TEST_URL" | grep -v "Date:"
else
    log "WARNING: Could not access EESSI repository via HTTP"
    log "Please check your firewall settings (ports 80 and 8000 need to be open)"
    log "You can try manually: curl --head $TEST_URL"
fi

#------------------------------------------------------------------------------
# 10. Final summary
#------------------------------------------------------------------------------
log "EESSI Stratum 1 server setup completed"

echo ""
echo "======================================================"
echo "EESSI Stratum 1 Server Setup Summary"
echo "======================================================"
echo "Stratum 1 server: $STRATUM1_SERVER"
if [ -n "$CUSTOM_STORAGE_DIR" ]; then
    echo "Storage location: $CUSTOM_STORAGE_DIR (symlinked from /srv/cvmfs)"
else
    echo "Storage location: /srv/cvmfs (default)"
fi
echo "Repository: $REPOSITORY"
echo "GeoAPI enabled: $USE_GEOAPI"
echo ""
echo "To verify your Stratum 1 server, run:"
echo "  curl --head $TEST_URL"
echo ""
echo "To point clients to this Stratum 1, configure their"
echo "/etc/cvmfs/domain.d/eessi.io.conf with:"
echo "CVMFS_SERVER_URL=\"http://$VERIFY_HOST/cvmfs/@fqrn@\""
if [ "$USE_GEOAPI" = "no" ]; then
    echo "CVMFS_USE_GEOAPI=no"
fi
echo ""
echo "Ensure that ports 80 and 8000 are open to clients"
echo "======================================================"

exit 0
