#!/bin/bash
#==============================================================================
# EESSI Stratum 1 Setup Script
#==============================================================================
# Author:      Diego Lasa
# Description: Sets up an EESSI Stratum 1 server using Ansible
#              following official EESSI documentation
# Usage:       sudo ./eessi_stratum1_setup.sh [options]
#              
# Environment: EESSI_STRATUM1_IP    - IP address of the Stratum 1 server
#              EESSI_STORAGE_DIR    - Custom storage location for CVMFS
#                                    (default: /lscratch/cvmfs)
#              EESSI_SSH_USER       - SSH username for Ansible connection
#              EESSI_LOG_LEVEL      - Logging level (INFO, DEBUG, ERROR)
#
# Options:     -i IP_ADDRESS        IP address of Stratum 1 server
#              -u USER              SSH username for Ansible connection
#              -s STORAGE_DIR       Custom storage location for CVMFS
#              -r REPOSITORY        Repository to replicate (default: software.eessi.io)
#              -l LOG_LEVEL         Set logging level (INFO, DEBUG, ERROR)
#              -y                   Assume yes to all prompts (non-interactive mode)
#              -h                   Show this help message
#
# Example:     EESSI_STRATUM1_IP=10.1.1.8 EESSI_STORAGE_DIR=/data/cvmfs \
#              sudo -E ./eessi_stratum1_setup.sh
#
# Notes:       This script assumes you're running it on the server that will
#              become the Stratum 1, or from a machine that can SSH to it.
#==============================================================================

# Strict mode
set -e  # Exit immediately if a command exits with a non-zero status
set -u  # Treat unset variables as an error

#------------------------------------------------------------------------------
# Global variables and constants
#------------------------------------------------------------------------------
# Script version
VERSION="1.0.0"

# Default values
DEFAULT_STRATUM1_IP=""           # Will be auto-detected if empty
DEFAULT_STORAGE_DIR="/lscratch/cvmfs"  # Default storage location
DEFAULT_SSH_USER="$(whoami)"     # Default SSH user
DEFAULT_LOG_LEVEL="INFO"         # Default log level
DEFAULT_REPOSITORY="software.eessi.io"  # Default repository to replicate
DEFAULT_LOG_FILE="/var/log/eessi_stratum1_setup.log"  # Default log file

# Initial values (will be overridden by env vars or command line args)
STRATUM1_IP="${EESSI_STRATUM1_IP:-$DEFAULT_STRATUM1_IP}"
STORAGE_DIR="${EESSI_STORAGE_DIR:-$DEFAULT_STORAGE_DIR}"
SSH_USER="${EESSI_SSH_USER:-$DEFAULT_SSH_USER}"
LOG_LEVEL="${EESSI_LOG_LEVEL:-$DEFAULT_LOG_LEVEL}"
REPOSITORY="$DEFAULT_REPOSITORY"
LOG_FILE="$DEFAULT_LOG_FILE"
NON_INTERACTIVE=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

#------------------------------------------------------------------------------
# Functions for logging and error handling
#------------------------------------------------------------------------------
# Display a formatted message
# Usage: print_message "MESSAGE" [COLOR]
print_message() {
    local message="$1"
    local color="${2:-$NC}"
    echo -e "${color}${message}${NC}"
}

# Log messages with timestamp and optional level
# Usage: log "MESSAGE" [LEVEL]
log() {
    local message="$1"
    local level="${2:-INFO}"
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    
    # Skip DEBUG messages if log level is not DEBUG
    if [ "$level" = "DEBUG" ] && [ "$LOG_LEVEL" != "DEBUG" ]; then
        return 0
    fi
    
    # Choose color based on level
    local color="$NC"
    case "$level" in
        INFO)    color="$NC" ;;
        WARNING) color="$YELLOW" ;;
        ERROR)   color="$RED" ;;
        SUCCESS) color="$GREEN" ;;
        DEBUG)   color="$BLUE" ;;
    esac
    
    echo -e "${color}[$timestamp] [$level] $message${NC}" | tee -a "$LOG_FILE"
}

# Error handler function
error_handler() {
    local line_number=$1
    local command=$2
    local exit_code=$3
    log "Error in command '$command' at line $line_number with exit code $exit_code" "ERROR"
    log "Script execution failed. Check the log file for details: $LOG_FILE" "ERROR"
    exit $exit_code
}

# Set up error trap
trap 'error_handler ${LINENO} "$BASH_COMMAND" $?' ERR

# Check if command succeeded
# Usage: check_success "MESSAGE" [EXIT_ON_FAILURE]
check_success() {
    local message="$1"
    local exit_on_failure="${2:-true}"
    
    if [ $? -eq 0 ]; then
        log "$message" "SUCCESS"
        return 0
    else
        log "$message failed with exit code $?" "ERROR"
        if [ "$exit_on_failure" = true ]; then
            exit 1
        fi
        return 1
    fi
}

# Function to show usage/help
show_help() {
    echo "EESSI Stratum 1 Setup Script v$VERSION"
    echo
    echo "Usage: $0 [options]"
    echo
    echo "Options:"
    echo "  -i IP_ADDRESS      IP address of Stratum 1 server"
    echo "  -u USER            SSH username for Ansible connection (default: $DEFAULT_SSH_USER)"
    echo "  -s STORAGE_DIR     Custom storage location for CVMFS (default: $DEFAULT_STORAGE_DIR)"
    echo "  -r REPOSITORY      Repository to replicate (default: $DEFAULT_REPOSITORY)"
    echo "  -l LOG_LEVEL       Set logging level: INFO, DEBUG, ERROR (default: $DEFAULT_LOG_LEVEL)"
    echo "  -y                 Assume yes to all prompts (non-interactive mode)"
    echo "  -h                 Show this help message"
    echo
    echo "Environment Variables:"
    echo "  EESSI_STRATUM1_IP   IP address of the Stratum 1 server"
    echo "  EESSI_STORAGE_DIR   Custom storage location for CVMFS"
    echo "  EESSI_SSH_USER      SSH username for Ansible connection"
    echo "  EESSI_LOG_LEVEL     Logging level (INFO, DEBUG, ERROR)"
    echo
    echo "Example:"
    echo "  $0 -i 10.1.1.8 -u root -s /data/cvmfs"
    echo
    echo "For bug reports and feedback, please contact the EESSI team."
    exit 0
}

#------------------------------------------------------------------------------
# Utility functions
#------------------------------------------------------------------------------
# Check if running as root or with sudo
check_privileges() {
    if [ "$(id -u)" -ne 0 ]; then
        log "This script must be run as root or with sudo" "ERROR"
        exit 1
    fi
}

# Check if required commands are available
check_dependencies() {
    local missing_deps=false
    
    for cmd in git curl sed grep; do
        if ! command -v $cmd &> /dev/null; then
            log "Required command not found: $cmd" "ERROR"
            missing_deps=true
        fi
    done
    
    if [ "$missing_deps" = true ]; then
        log "Please install the missing dependencies and try again" "ERROR"
        exit 1
    fi
}

# Initialize log file
initialize_log() {
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    touch "$LOG_FILE" 2>/dev/null || {
        LOG_FILE="./eessi_stratum1_setup.log"
        touch "$LOG_FILE"
        log "Could not create log in /var/log, using $LOG_FILE instead" "WARNING"
    }
    log "Log initialized at $LOG_FILE" "DEBUG"
}

# Auto-detect IP if needed
detect_ip() {
    if [ -z "$STRATUM1_IP" ]; then
        STRATUM1_IP=$(hostname -I | awk '{print $1}')
        if [ -z "$STRATUM1_IP" ]; then
            log "Could not auto-detect IP address. Please specify with -i option." "ERROR"
            exit 1
        fi
        log "Auto-detected Stratum 1 IP: $STRATUM1_IP" "INFO"
    fi
}

# Confirm action with user
# Usage: confirm_action "MESSAGE" [DEFAULT_YES]
confirm_action() {
    local message="$1"
    local default_yes="${2:-false}"
    local prompt
    local response
    
    # Skip confirmation in non-interactive mode
    if [ "$NON_INTERACTIVE" = true ]; then
        return 0
    fi
    
    if [ "$default_yes" = true ]; then
        prompt="$message [Y/n] "
        read -p "$prompt" response
        response=${response:-Y}
    else
        prompt="$message [y/N] "
        read -p "$prompt" response
        response=${response:-N}
    fi
    
    case "$response" in
        [yY][eE][sS]|[yY]) 
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

#------------------------------------------------------------------------------
# Core functions
#------------------------------------------------------------------------------
# Install Ansible if not already installed
install_ansible() {
    log "Checking for Ansible installation..." "DEBUG"
    
    if ! command -v ansible >/dev/null 2>&1; then
        log "Installing Ansible..." "INFO"
        
        if [ -f /usr/bin/dnf ]; then
            dnf install -y ansible
        elif [ -f /usr/bin/yum ]; then
            yum install -y ansible
        elif [ -f /usr/bin/apt ]; then
            apt update
            apt install -y ansible
        else
            log "Unsupported package manager. Please install Ansible manually." "ERROR"
            exit 1
        fi
        
        check_success "Ansible installation"
    else
        log "Ansible is already installed" "INFO"
    fi
}

# Clone the EESSI filesystem-layer repository
clone_repository() {
    log "Checking for EESSI filesystem-layer repository..." "DEBUG"
    
    if [ ! -d "filesystem-layer" ]; then
        log "Cloning EESSI filesystem-layer repository..." "INFO"
        git clone https://github.com/EESSI/filesystem-layer.git
        check_success "Repository cloning"
    else
        log "EESSI filesystem-layer repository directory already exists" "INFO"
        
        if confirm_action "Do you want to update the repository?" true; then
            log "Updating repository..." "INFO"
            ( cd filesystem-layer && git pull )
            check_success "Repository update"
        fi
    fi
    
    cd filesystem-layer
    log "Working directory: $(pwd)" "DEBUG"
}

# Install Ansible roles
install_ansible_roles() {
    log "Installing required Ansible roles..." "INFO"
    ansible-galaxy role install -r ./requirements.yml --force
    check_success "Ansible roles installation"
}

# Set up storage
setup_storage() {
    log "Setting up storage location: $STORAGE_DIR" "INFO"
    
    local is_local=false
    if [[ "$STRATUM1_IP" == "localhost" || "$STRATUM1_IP" == "127.0.0.1" || "$STRATUM1_IP" == $(hostname -I | awk '{print $1}') ]]; then
        is_local=true
    fi
    
    if [ "$is_local" = true ]; then
        # Local setup
        mkdir -p "$STORAGE_DIR"
        
        # Remove any existing symlink
        if [ -L "/srv/cvmfs" ]; then
            log "Removing existing symlink /srv/cvmfs" "DEBUG"
            unlink /srv/cvmfs
        fi
        
        mkdir -p /srv
        log "Creating symlink from /srv/cvmfs to $STORAGE_DIR" "INFO"
        ln -sf "$STORAGE_DIR" /srv/cvmfs
    else
        # Remote setup
        log "For remote servers, please ensure the following is done on the target server:" "WARNING"
        log "  1. Create directory: mkdir -p $STORAGE_DIR" "WARNING"
        log "  2. Create symlink: ln -sf $STORAGE_DIR /srv/cvmfs" "WARNING"
        
        if ! confirm_action "Have you completed these steps on the remote server?" false; then
            log "Storage setup not confirmed. Exiting." "ERROR"
            exit 1
        fi
    fi
    check_success "Storage setup"
}

# Create hosts file for Ansible
create_hosts_file() {
    log "Creating Ansible inventory hosts file..." "INFO"
    
    mkdir -p inventory
    cat > inventory/hosts << EOF
[cvmfsstratum1servers]
$STRATUM1_IP ansible_ssh_user=$SSH_USER
EOF
    check_success "Hosts file creation"
    log "Created hosts file with IP: $STRATUM1_IP and user: $SSH_USER" "DEBUG"
}

# Modify all.yml to only include software.eessi.io
modify_all_yml() {
    log "Modifying all.yml to only include $REPOSITORY..." "INFO"
    
    # Check if the file exists
    if [ -f "inventory/group_vars/all.yml" ]; then
        # Create a backup
        cp "inventory/group_vars/all.yml" "inventory/group_vars/all.yml.bak"
        log "Backup created: inventory/group_vars/all.yml.bak" "DEBUG"
        
        # Use sed to remove other repositories, if they exist
        if grep -q "repository: riscv.eessi.io" "inventory/group_vars/all.yml"; then
            # Find the start line of riscv.eessi.io repository
            start_line=$(grep -n "repository: riscv.eessi.io" "inventory/group_vars/all.yml" | cut -d: -f1)
            
            # Find the end line (either the start of the next repository or end of the repositories section)
            next_repo_line=$(tail -n +$((start_line+1)) "inventory/group_vars/all.yml" | grep -n "  - repository:" | head -1 | cut -d: -f1)
            if [ -n "$next_repo_line" ]; then
                end_line=$((start_line + next_repo_line - 1))
                # Delete from start line to the line before the next repository
                sed -i "${start_line},${end_line}d" "inventory/group_vars/all.yml"
            else
                # No next repository, look for the next major section
                next_section_line=$(tail -n +$((start_line+1)) "inventory/group_vars/all.yml" | grep -n "^[a-z]" | head -1 | cut -d: -f1)
                if [ -n "$next_section_line" ]; then
                    end_line=$((start_line + next_section_line - 1))
                    # Delete from start line to the line before the next section
                    sed -i "${start_line},${end_line}d" "inventory/group_vars/all.yml"
                fi
            fi
            log "Removed riscv.eessi.io repository from all.yml" "DEBUG"
        fi
        
        # Check if dev.eessi.io exists in the file
        if grep -q "repository: dev.eessi.io" "inventory/group_vars/all.yml"; then
            # Find the start line of dev.eessi.io repository
            start_line=$(grep -n "repository: dev.eessi.io" "inventory/group_vars/all.yml" | cut -d: -f1)
            
            # Find the end line (end of the repositories section, usually the start of the next major section)
            next_section_line=$(tail -n +$((start_line+1)) "inventory/group_vars/all.yml" | grep -n "^[a-z]" | head -1 | cut -d: -f1)
            if [ -n "$next_section_line" ]; then
                end_line=$((start_line + next_section_line - 1))
                # Delete from start line to the line before the next section
                sed -i "${start_line},${end_line}d" "inventory/group_vars/all.yml"
            fi
            log "Removed dev.eessi.io repository from all.yml" "DEBUG"
        fi
        
        log "Modified all.yml to only include $REPOSITORY" "SUCCESS"
    else
        log "WARNING: all.yml not found in inventory/group_vars/" "WARNING"
        log "Make sure you're in the filesystem-layer directory and the file structure is intact" "WARNING"
    fi
}

# Run the Ansible playbook
run_playbook() {
    log "Ready to run Ansible playbook to deploy Stratum 1 server" "INFO"
    log "This will install and configure EESSI Stratum 1 for $REPOSITORY" "INFO"
    
    # Prompt for confirmation unless in non-interactive mode
    if [ "$NON_INTERACTIVE" = false ]; then
        log "Press Enter to continue or Ctrl+C to abort" "INFO"
        read -r
    fi
    
    PLAYBOOK_CMD="ansible-playbook -b"
    
    # Add -K if we're connecting to a remote server that may need password for sudo
    if [[ "$STRATUM1_IP" != "localhost" && "$STRATUM1_IP" != "127.0.0.1" && "$STRATUM1_IP" != $(hostname -I | awk '{print $1}') ]]; then
        if [ "$NON_INTERACTIVE" = false ]; then
            PLAYBOOK_CMD="$PLAYBOOK_CMD -K"
        else
            log "Warning: Running in non-interactive mode with a remote server." "WARNING"
            log "Sudo password may be required but cannot be prompted for." "WARNING"
        fi
    fi
    
    # Add additional verbosity for DEBUG log level
    if [ "$LOG_LEVEL" = "DEBUG" ]; then
        PLAYBOOK_CMD="$PLAYBOOK_CMD -vv"
    fi
    
    # Run the playbook
    log "Running Ansible playbook: $PLAYBOOK_CMD stratum1.yml" "INFO"
    eval "$PLAYBOOK_CMD stratum1.yml"
    check_success "Ansible playbook execution"
}

# Verify the installation
verify_installation() {
    log "Verifying Stratum 1 server installation..." "INFO"
    
    # Determine the hostname/IP to use for verification
    local VERIFY_HOST
    if [[ "$STRATUM1_IP" == "localhost" || "$STRATUM1_IP" == "127.0.0.1" ]]; then
        # Use hostname if localhost
        VERIFY_HOST=$(hostname -f)
    else
        VERIFY_HOST="$STRATUM1_IP"
    fi
    
    TEST_URL="http://$VERIFY_HOST/cvmfs/$REPOSITORY/.cvmfspublished"
    
    log "Testing access to EESSI repository with: curl --head $TEST_URL" "INFO"
    if curl --head "$TEST_URL" &>/dev/null; then
        log "EESSI repository is accessible!" "SUCCESS"
        log "Response headers:" "INFO"
        curl --head "$TEST_URL" | grep -v "Date:"
        return 0
    else
        log "Could not access EESSI repository via HTTP" "WARNING"
        log "Please check your Apache configuration and firewall settings (port 80 needs to be open)" "WARNING"
        log "You can try manually: curl --head $TEST_URL" "INFO"
        return 1
    fi
}

# Display final summary
display_summary() {
    local VERIFY_HOST
    if [[ "$STRATUM1_IP" == "localhost" || "$STRATUM1_IP" == "127.0.0.1" ]]; then
        VERIFY_HOST=$(hostname -f)
    else
        VERIFY_HOST="$STRATUM1_IP"
    fi
    
    log "EESSI Stratum 1 server setup completed" "SUCCESS"
    
    print_message "\n======================================================" "$BLUE"
    print_message "EESSI Stratum 1 Server Setup Summary" "$BLUE"
    print_message "======================================================" "$BLUE"
    print_message "Stratum 1 server: $STRATUM1_IP"
    print_message "Storage location: $STORAGE_DIR (symlinked from /srv/cvmfs)"
    print_message "Repository: $REPOSITORY"
    print_message ""
    print_message "To verify your Stratum 1 server, run:"
    print_message "  curl --head http://$VERIFY_HOST/cvmfs/$REPOSITORY/.cvmfspublished"
    print_message ""
    print_message "To point clients to this Stratum 1, configure their"
    print_message "/etc/cvmfs/domain.d/eessi.io.conf with:"
    print_message "CVMFS_SERVER_URL=\"http://$VERIFY_HOST/cvmfs/@fqrn@\""
    print_message "CVMFS_USE_GEOAPI=no"
    print_message ""
    print_message "Ensure that port 80 is open to clients"
    print_message "======================================================" "$BLUE"
}

#------------------------------------------------------------------------------
# Parse command line arguments
#------------------------------------------------------------------------------
parse_arguments() {
    while getopts ":i:u:s:r:l:yh" opt; do
        case ${opt} in
            i)
                STRATUM1_IP=$OPTARG
                ;;
            u)
                SSH_USER=$OPTARG
                ;;
            s)
                STORAGE_DIR=$OPTARG
                ;;
            r)
                REPOSITORY=$OPTARG
                ;;
            l)
                LOG_LEVEL=$OPTARG
                if [[ ! "$LOG_LEVEL" =~ ^(INFO|DEBUG|ERROR)$ ]]; then
                    log "Invalid log level: $LOG_LEVEL. Using default: $DEFAULT_LOG_LEVEL" "WARNING"
                    LOG_LEVEL="$DEFAULT_LOG_LEVEL"
                fi
                ;;
            y)
                NON_INTERACTIVE=true
                ;;
            h)
                show_help
                ;;
            \?)
                log "Invalid option: -$OPTARG" "ERROR"
                show_help
                ;;
            :)
                log "Option -$OPTARG requires an argument" "ERROR"
                show_help
                ;;
        esac
    done
}

#------------------------------------------------------------------------------
# Main function
#------------------------------------------------------------------------------
main() {
    # Parse command line arguments
    parse_arguments "$@"
    
    # Initialize the log
    initialize_log
    
    # Check dependencies
    check_dependencies
    
    # Check if running with proper privileges
    check_privileges
    
    # Detect IP if not specified
    detect_ip
    
    # Display configuration
    log "Starting EESSI Stratum 1 server setup v$VERSION" "INFO"
    log "Target server: $STRATUM1_IP" "INFO"
    log "SSH user: $SSH_USER" "INFO"
    log "Storage directory: $STORAGE_DIR" "INFO"
    log "Repository to replicate: $REPOSITORY" "INFO"
    log "Non-interactive mode: $NON_INTERACTIVE" "DEBUG"
    
    # Main execution steps
    install_ansible
    clone_repository
    install_ansible_roles
    setup_storage
    create_hosts_file
    modify_all_yml
    run_playbook
    verify_installation
    display_summary
    
    log "Script execution completed successfully" "SUCCESS"
    exit 0
}

# Run the main function with all arguments
main "$@"
