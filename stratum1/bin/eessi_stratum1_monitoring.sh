#!/bin/bash
#==============================================================================
# EESSI Stratum 1 Monitoring Script
#==============================================================================
# Author:      Diego Lasa
# Description: User-friendly monitoring for EESSI Stratum 1 server
#
# Usage:       ./eessi_stratum1_monitor.sh [options]
#
# Options:     -r REPO       Repository name (default: software.eessi.io)
#              -o FILE       Generate HTML report to specified file
#              -e EMAIL      Send report to email address
#              -s SERVER     Stratum 0 server to check against (can be specified multiple times)
#              -S FILE       File containing a list of Stratum 0 servers (one per line)
#              -h            Show this help
#
# Examples:    ./eessi_stratum1_monitor.sh
#              ./eessi_stratum1_monitor.sh -o /var/www/html/eessi-report.html
#              ./eessi_stratum1_monitor.sh -s cvmfs-stratum0.example.org
#==============================================================================
#
eessi-report.html
#              ./eessi_stratum1_monitor.sh -s cvmfs-stratum0.example.org
#==============================================================================

# ======================
# Configuration
# ======================
REPO="software.eessi.io"
DATA_DIR="/var/log/eessi/metrics"
OUTPUT_FILE=""
EMAIL=""
CVMFS_BASE="/srv/cvmfs"

# Array to hold Stratum 0 servers
declare -a STRATUM0_SERVERS
# Add a useful function to test connectivity to Stratum 0 servers
test_stratum0_connectivity() {
    local server="$1"
    local repo="$2"
    
    # First try simple ping
    if ! ping -c 1 -W 2 "$server" &>/dev/null; then
        return 1
    fi
    
    # Then try HTTP connection
    if ! curl --silent --head --fail --max-time 5 "http://$server/cvmfs/$repo/.cvmfspublished" &>/dev/null; then
        return 2
    fi
    
    return 0
}

# Detect log files based on system type
if [ -d "/var/log/httpd" ]; then
    # RHEL/CentOS style
    WEB_LOG="/var/log/httpd/access_log"
else
    # Debian/Ubuntu style
    WEB_LOG="/var/log/apache2/access.log"
fi

# Current date/time
TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")
DATE_SHORT=$(date +"%Y-%m-%d")

# Text formatting
BOLD="\033[1m"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
BLUE="\033[34m"
RESET="\033[0m"

# ======================
# Process command line args
# ======================
while getopts "r:o:e:s:S:h" opt; do
    case ${opt} in
        r)
            REPO=$OPTARG
            ;;
        o)
            OUTPUT_FILE=$OPTARG
            ;;
        e)
            EMAIL=$OPTARG
            ;;
        s)
            STRATUM0_SERVERS+=("$OPTARG")
            ;;
        S)
            if [ -f "$OPTARG" ]; then
                while read -r server; do
                    # Skip empty lines and comments
                    if [[ -n "$server" && ! "$server" =~ ^[[:space:]]*# ]]; then
                        STRATUM0_SERVERS+=("$server")
                    fi
                done < "$OPTARG"
            else
                echo "Warning: Stratum 0 servers list file not found: $OPTARG"
            fi
            ;;
        h)
            echo "Usage: $0 [options]"
            echo "Options:"
            echo "  -r REPO       Repository name (default: software.eessi.io)"
            echo "  -o FILE       Generate HTML report to specified file"
            echo "  -e EMAIL      Send report to email address"
            echo "  -s SERVER     Stratum 0 server to check against (can be specified multiple times)"
            echo "  -S FILE       File containing a list of Stratum 0 servers (one per line)"
            echo "  -h            Show this help"
            exit 0
            ;;
        *)
            echo "Invalid option: $OPTARG" 1>&2
            exit 1
            ;;
    esac
done

# ======================
# Helper functions
# ======================

# Create directory if it doesn't exist
ensure_dir() {
    if [ ! -d "$1" ]; then
        mkdir -p "$1" 2>/dev/null || { 
            echo -e "${RED}ERROR: Cannot create directory $1${RESET}"
            return 1
        }
    fi
    return 0
}

# Print section header
print_header() {
    echo
    echo -e "${BOLD}${BLUE}=== $1 ===${RESET}"
    echo
}

# Print success message
print_success() {
    echo -e "${GREEN}✓ $1${RESET}"
}

# Print warning message
print_warning() {
    echo -e "${YELLOW}⚠ $1${RESET}"
}

# Print error message
print_error() {
    echo -e "${RED}✗ $1${RESET}"
}

# Print info message
print_info() {
    echo -e "$1"
}

# Save data to CSV
save_data() {
    local file="$1"
    local data="$2"
    
    ensure_dir "$(dirname "$file")"
    echo "$data" >> "$file"
}

# ======================
# Main monitoring functions
# ======================

# Check repository size
check_repo_size() {
    print_header "Repository Size"
    
    local repo_path="$CVMFS_BASE/$REPO"
    
    if [ ! -d "$repo_path" ]; then
        print_error "Repository not found: $repo_path"
        return 1
    fi
    
    # Get size information
    print_info "Calculating repository size (this may take a moment)..."
    local size_kb=$(du -sk "$repo_path" 2>/dev/null | cut -f1)
    if [ -z "$size_kb" ]; then
        print_error "Failed to calculate repository size"
        return 1
    fi
    
    local size_mb=$(echo "scale=2; $size_kb / 1024" | bc)
    local size_gb=$(echo "scale=2; $size_mb / 1024" | bc)
    
    # Count files
    print_info "Counting files..."
    local num_files=$(find "$repo_path" -type f | wc -l)
    
    # Save data
    save_data "$DATA_DIR/daily/repo_size.csv" "$DATE_SHORT,$size_kb,$size_mb,$size_gb,$num_files"
    
    # Display results
    print_success "Size: ${BOLD}${size_gb} GB${RESET} (${num_files} files)"

    return 0
}

# Check CVMFS catalog
check_catalog() {
    print_header "CVMFS Catalog Information"
    
    local repo_path="$CVMFS_BASE/$REPO"
    local revision="unknown"
    local catalog_size="unknown"
    local catalog_files="unknown"
    local root_hash="unknown"
    local published_timestamp="unknown"
    
    if [ ! -d "$repo_path" ]; then
        print_error "Repository not found: $repo_path"
        return 1
    fi
    
    # Try to get catalog info with cvmfs_server 
    if command -v cvmfs_server &> /dev/null; then
        local catalog_info=$(cvmfs_server info "$REPO" 2>/dev/null)
        
        if [ $? -eq 0 ] && [ -n "$catalog_info" ] && grep -q "Revision" <<< "$catalog_info"; then
            revision=$(echo "$catalog_info" | grep "Revision" | awk '{print $2}')
            catalog_size=$(echo "$catalog_info" | grep "Catalog size" | awk '{print $3}')
            catalog_files=$(echo "$catalog_info" | grep "Total number of files" | awk '{print $5}')
            
            print_success "Catalog information retrieved successfully"
        else
            print_warning "Could not get catalog info using cvmfs_server"
        fi
    else
        print_warning "cvmfs_server command not found"
    fi
    
    # Try to extract information directly from .cvmfspublished file
    if [ -f "$repo_path/.cvmfspublished" ]; then
        print_info "Analyzing .cvmfspublished file..."
        
        # Extract revision from .cvmfspublished (which is a key-value store)
        if [ "$revision" = "unknown" ]; then
            # Try to get revision (usually stored with key S or X)
            revision=$(dd if="$repo_path/.cvmfspublished" bs=1 count=40 2>/dev/null | grep -a -o -E '[0-9a-f]{8}' | head -1)
            
            if [ -z "$revision" ]; then
                # Alternative method using hexdump
                revision=$(hexdump -n 20 -e '"%x"' "$repo_path/.cvmfspublished" 2>/dev/null | grep -o -E '[0-9a-f]{8}' | head -1)
            fi
        fi
        
        # Try to get root catalog hash (stored with key C)
        root_hash=$(grep -a -o -E 'C[0-9a-f]{40}' "$repo_path/.cvmfspublished" 2>/dev/null | cut -c2-)
        if [ -z "$root_hash" ]; then
            # Alternative approach
            root_hash=$(hexdump -ve '1/1 "%.2x"' "$repo_path/.cvmfspublished" 2>/dev/null | grep -o -E '43[0-9a-f]{40}' | head -1 | cut -c3-)
        fi
        
        # Try to get timestamp (stored with key T)
        published_timestamp=$(grep -a -o -E 'T[0-9]{10}' "$repo_path/.cvmfspublished" 2>/dev/null | cut -c2-)
        if [ -n "$published_timestamp" ]; then
            # Convert Unix timestamp to human-readable date
            if command -v date &> /dev/null; then
                published_timestamp="$(date -d @$published_timestamp 2>/dev/null)"
            fi
        fi
    fi
    
    # Estimate catalog files by checking .cvmfs directory or using find
    if [ "$catalog_files" = "unknown" ]; then
        if [ -d "$repo_path/.cvmfs/catalogs" ]; then
            catalog_files=$(find "$repo_path/.cvmfs/catalogs" -type f | wc -l)
        fi
    fi
    
    # Estimate catalog size if still unknown
    if [ "$catalog_size" = "unknown" ]; then
        if [ -d "$repo_path/.cvmfs" ]; then
            catalog_size=$(du -sh "$repo_path/.cvmfs/catalogs" 2>/dev/null | awk '{print $1}')
        elif [ -f "$repo_path/.cvmfscatalog" ]; then
            catalog_size=$(du -h "$repo_path/.cvmfscatalog" 2>/dev/null | cut -f1)
        fi
    fi
    
    # Display catalog information
    if [ "$revision" != "unknown" ]; then
        print_info "  • Revision: ${BOLD}$revision${RESET}"
    else
        print_warning "  • Revision: Could not be determined"
    fi
    
    if [ "$root_hash" != "unknown" ]; then
        print_info "  • Root Hash: ${BOLD}$root_hash${RESET}"
    fi
    
    if [ "$published_timestamp" != "unknown" ]; then
        print_info "  • Published: ${BOLD}$published_timestamp${RESET}"
    fi
    
    if [ "$catalog_size" != "unknown" ]; then
        print_info "  • Catalog size: ${BOLD}$catalog_size${RESET}"
    fi
    
    if [ "$catalog_files" != "unknown" ]; then
        print_info "  • Catalog files: ${BOLD}$catalog_files${RESET}"
    fi
    
    # Save data
    save_data "$DATA_DIR/hourly/catalog_stats.csv" "$TIMESTAMP,$revision,$catalog_size,$catalog_files,$root_hash,$published_timestamp"
    
    return 0
}

# Check web server status and client connections
check_web_server() {
    print_header "Web Server Status & Client Connections"
    
    # Check if web server is running
    local web_service=""
    
    if systemctl is-active httpd &>/dev/null; then
        web_service="httpd"
        print_success "Web server (httpd) is running"
    elif systemctl is-active apache2 &>/dev/null; then
        web_service="apache2"
        print_success "Web server (apache2) is running"
    else
        print_warning "Could not determine if web server is running"
    fi
    
    # Check if repository is accessible via HTTP
    local server_host=$(hostname -f)
    
    if curl --silent --head --fail "http://$server_host/cvmfs/$REPO/.cvmfspublished" &>/dev/null; then
        print_success "Repository is accessible via HTTP"
    else
        print_warning "Repository is NOT accessible via HTTP"
        print_info "  Test with: curl --head http://$server_host/cvmfs/$REPO/.cvmfspublished"
    fi
    
    # Analyze web server logs if available
    if [ -f "$WEB_LOG" ]; then
        print_info "Analyzing web server logs..."
        
        # Check for repository access in logs
        if grep -q "$REPO" "$WEB_LOG"; then
            # Extract client information
            local unique_clients=$(grep "$REPO" "$WEB_LOG" | tail -1000 | awk '{print $1}' | sort | uniq | wc -l)
            local total_requests=$(grep "$REPO" "$WEB_LOG" | tail -1000 | wc -l)
            
            # HTTP status codes
            local status_200=$(grep "$REPO" "$WEB_LOG" | tail -1000 | grep -E ' 200 | HTTP/1\.1" 200 ' | wc -l)
            local status_304=$(grep "$REPO" "$WEB_LOG" | tail -1000 | grep -E ' 304 | HTTP/1\.1" 304 ' | wc -l)
            local status_404=$(grep "$REPO" "$WEB_LOG" | tail -1000 | grep -E ' 404 | HTTP/1\.1" 404 ' | wc -l)
            local status_other=$(( total_requests - status_200 - status_304 - status_404 ))
            
            # Display results
            print_success "Found ${BOLD}$unique_clients${RESET} unique clients with ${BOLD}$total_requests${RESET} recent requests"
            print_info "  • Status 200 (OK): $status_200"
            print_info "  • Status 304 (Not Modified): $status_304"
            print_info "  • Status 404 (Not Found): $status_404"
            print_info "  • Other status codes: $status_other"
            
            # Show top clients
            if [ "$unique_clients" -gt 0 ]; then
                print_info "\nTop active clients:"
                grep "$REPO" "$WEB_LOG" | tail -1000 | awk '{print $1}' | sort | uniq -c | sort -nr | head -5 | \
                    while read count ip; do
                        printf "  • %-15s %s requests\n" "$ip" "$count"
                    done
            fi
            
            # Save data
            save_data "$DATA_DIR/hourly/apache_stats.csv" "$TIMESTAMP,$unique_clients,$total_requests,$status_200,$status_304,$status_404,$status_other"
            
        else
            print_warning "No entries for $REPO found in web server logs"
        fi
    else
        print_warning "Web server log not found: $WEB_LOG"
    fi
    
    return 0
}

# Check Squid proxy status
check_squid() {
    print_header "Squid Proxy Status"
    
    local squid_running=false
    
    # Check if Squid is running
    if systemctl is-active squid &>/dev/null; then
        print_success "Squid proxy is running"
        squid_running=true
    elif systemctl is-active squid3 &>/dev/null; then
        print_success "Squid proxy (squid3) is running"
        squid_running=true
    else
        print_warning "Squid proxy is not running"
    fi
    
    # Look for Squid logs
    local squid_log=""
    for log_file in /var/log/squid/access.log /var/log/squid3/access.log /var/log/squid/access_log; do
        if [ -f "$log_file" ]; then
            squid_log="$log_file"
            break
        fi
    done
    
    # Analyze Squid logs if available
    if [ -n "$squid_log" ] && [ -f "$squid_log" ]; then
        print_info "Analyzing Squid logs: $squid_log"
        
        if grep -q "$REPO" "$squid_log"; then
            # Extract cache statistics
            local total_requests=$(grep "$REPO" "$squid_log" | tail -1000 | wc -l)
            local cache_hits=$(grep "$REPO" "$squid_log" | tail -1000 | grep -E "TCP_HIT|TCP_MEM_HIT|TCP_IMS_HIT" | wc -l)
            local cache_misses=$(grep "$REPO" "$squid_log" | tail -1000 | grep -E "TCP_MISS|TCP_REFRESH_MISS" | wc -l)
            
            # Calculate hit rate
            local hit_rate=0
            if [ "$total_requests" -gt 0 ]; then
                hit_rate=$(echo "scale=2; ($cache_hits * 100) / $total_requests" | bc)
            fi
            
            # Display results
            print_success "Cache statistics for recent requests:"
            print_info "  • Total requests: $total_requests"
            print_info "  • Cache hits: $cache_hits"
            print_info "  • Cache misses: $cache_misses"
            print_info "  • Hit rate: ${BOLD}${hit_rate}%${RESET}"
            
            # Save data
            save_data "$DATA_DIR/hourly/squid_stats.csv" "$TIMESTAMP,$total_requests,$cache_hits,$cache_misses,$hit_rate"
        else
            print_warning "No entries for $REPO found in Squid logs"
        fi
    else
        if [ "$squid_running" = true ]; then
            print_warning "Squid is running but no log file found"
        else
            print_info "Squid is not running - no logs to analyze"
        fi
        
        # Save empty data
        save_data "$DATA_DIR/hourly/squid_stats.csv" "$TIMESTAMP,0,0,0,0"
    fi
    
    return 0
}

# Check disk space
check_disk_space() {
    print_header "Disk Space"
    
    local disk_usage=$(df -h "$CVMFS_BASE" | awk 'NR==2 {print $5}')
    local disk_available=$(df -h "$CVMFS_BASE" | awk 'NR==2 {print $4}')
    local disk_total=$(df -h "$CVMFS_BASE" | awk 'NR==2 {print $2}')
    local disk_used=$(df -h "$CVMFS_BASE" | awk 'NR==2 {print $3}')
    local disk_mount=$(df -h "$CVMFS_BASE" | awk 'NR==2 {print $6}')
    
    # Display results
    print_info "Storage information for $CVMFS_BASE:"
    print_info "  • Mount point: $disk_mount"
    print_info "  • Total space: $disk_total"
    print_info "  • Used space: $disk_used ($disk_usage)"
    print_info "  • Available space: $disk_available"
    
    # Warning if disk usage is over 90%
    local usage_pct=${disk_usage%\%}
    if [ "$usage_pct" -gt 90 ]; then
        print_warning "Disk usage is over 90%! Consider freeing up space."
    elif [ "$usage_pct" -gt 80 ]; then
        print_warning "Disk usage is over 80%. Monitor space carefully."
    else
        print_success "Disk space usage is normal."
    fi
    
    return 0
}

# Discover available Stratum 0 servers
discover_stratum0_servers() {
    print_header "Discovering Stratum 0 Servers"
    
    # If servers were already specified, use them
    if [ ${#STRATUM0_SERVERS[@]} -gt 0 ]; then
        print_info "Using provided Stratum 0 servers: ${STRATUM0_SERVERS[*]}"
        return 0
    fi
    
    print_info "Attempting to discover Stratum 0 servers automatically..."
    
    # Check if we can use cvmfs_server to get replica information
    if command -v cvmfs_server &> /dev/null; then
        print_info "Checking replica configuration using cvmfs_server..."
        
        # Get replica information
        local replica_info=$(cvmfs_server info -r "$REPO" 2>/dev/null)
        
        if [ $? -eq 0 ] && [ -n "$replica_info" ]; then
            # Try to extract upstream (Stratum 0) URL
            local upstream_url=$(echo "$replica_info" | grep -E "^Upstream:" | sed 's/Upstream: //')
            
            if [ -n "$upstream_url" ]; then
                # Extract hostname from URL
                local upstream_host=$(echo "$upstream_url" | sed -E 's|^(http|https)://([^/]+)/.*|\2|')
                
                if [ -n "$upstream_host" ]; then
                    print_success "Found Stratum 0 server in replica configuration: $upstream_host"
                    STRATUM0_SERVERS+=("$upstream_host")
                fi
            fi
        else
            print_warning "Could not get replica information from cvmfs_server"
        fi
    fi
    
    # Try to find Stratum 0 servers from CVMFS client configuration
    if [ -d "/etc/cvmfs" ]; then
        print_info "Checking CVMFS client configuration..."
        
        # Check domain configuration files
        local domain_file="/etc/cvmfs/domain.d/eessi.io.conf"
        if [ -f "$domain_file" ]; then
            print_info "Checking domain configuration: $domain_file"
            
            # Extract URLs
            local stratum0_urls=$(grep -E "^CVMFS_SERVER_URL=" "$domain_file" | sed -E 's/CVMFS_SERVER_URL="([^"]*)".*/\1/' | tr ';' '\n')
            
            if [ -n "$stratum0_urls" ]; then
                # Extract hostnames from URLs
                for url in $stratum0_urls; do
                    local host=$(echo "$url" | sed -E 's|^(http|https)://([^/]+)/.*|\2|')
                    if [ -n "$host" ] && [[ ! " ${STRATUM0_SERVERS[*]} " =~ " $host " ]]; then
                        print_success "Found potential Stratum 0/1 server: $host"
                        STRATUM0_SERVERS+=("$host")
                    fi
                done
            fi
        fi
        
        # Check repository configuration files
        local repo_file="/etc/cvmfs/config.d/$REPO.conf"
        if [ -f "$repo_file" ]; then
            print_info "Checking repository configuration: $repo_file"
            
            # Extract URLs
            local stratum0_urls=$(grep -E "^CVMFS_SERVER_URL=" "$repo_file" | sed -E 's/CVMFS_SERVER_URL="([^"]*)".*/\1/' | tr ';' '\n')
            
            if [ -n "$stratum0_urls" ]; then
                # Extract hostnames from URLs
                for url in $stratum0_urls; do
                    local host=$(echo "$url" | sed -E 's|^(http|https)://([^/]+)/.*|\2|')
                    if [ -n "$host" ] && [[ ! " ${STRATUM0_SERVERS[*]} " =~ " $host " ]]; then
                        print_success "Found potential Stratum 0/1 server: $host"
                        STRATUM0_SERVERS+=("$host")
                    fi
                done
            fi
            
            # Check for explicit Stratum 0 URL
            local stratum0_url=$(grep -E "^CVMFS_STRATUM0=" "$repo_file" | sed -E 's/CVMFS_STRATUM0="([^"]*)".*/\1/')
            if [ -n "$stratum0_url" ]; then
                local host=$(echo "$stratum0_url" | sed -E 's|^(http|https)://([^/]+)/.*|\2|')
                if [ -n "$host" ] && [[ ! " ${STRATUM0_SERVERS[*]} " =~ " $host " ]]; then
                    print_success "Found explicit Stratum 0 server: $host"
                    STRATUM0_SERVERS+=("$host")
                fi
            fi
        fi
    fi
    
    # Add EESSI servers if none found
    if [ ${#STRATUM0_SERVERS[@]} -eq 0 ]; then
        print_warning "No Stratum 0 servers discovered automatically"
        
        # Known EESSI servers based on documentation
        if [[ "$REPO" == *"eessi"* ]]; then
            print_info "Adding known EESSI servers..."
            
            # Try with synchronization server first (for private Stratum 1 setup)
            local sync_server="aws-eu-west-s1-sync.eessi.science"
            print_info "Testing connectivity to synchronization server: $sync_server"
            
            if curl --silent --head --fail --max-time 5 "http://$sync_server/cvmfs/$REPO/.cvmfspublished" &>/dev/null; then
                print_success "Successfully connected to EESSI synchronization server: $sync_server"
                STRATUM0_SERVERS+=("$sync_server")
            else
                print_warning "Could not connect to EESSI synchronization server"
                
                # Try public Stratum 1 servers (as fallbacks for monitoring)
                local stratum1_servers=("cvmfs-s1.eessi-hpc.org" "aws-eu-west1.stratum1.cvmfs.eessi-infra.org" "cvmfs-egi.gridpp.rl.ac.uk")
                
                for server in "${stratum1_servers[@]}"; do
                    print_info "Testing connectivity to Stratum 1: $server"
                    if curl --silent --head --fail --max-time 5 "http://$server/cvmfs/$REPO/.cvmfspublished" &>/dev/null; then
                        print_success "Successfully connected to EESSI Stratum 1 server: $server"
                        STRATUM0_SERVERS+=("$server")
                        break
                    else
                        print_warning "Could not connect to $server"
                    fi
                done
                
                # If still no servers, add one with a note
                if [ ${#STRATUM0_SERVERS[@]} -eq 0 ]; then
                    print_warning "Could not connect to any known EESSI servers"
                    print_info "Adding EESSI server as fallback (connectivity will be checked later)"
                    STRATUM0_SERVERS+=("cvmfs-s1.eessi-hpc.org")
                fi
            fi
        fi
    fi
    
    # Output summary
    if [ ${#STRATUM0_SERVERS[@]} -gt 0 ]; then
        print_success "Discovered ${#STRATUM0_SERVERS[@]} potential servers for monitoring"
        local i=1
        for server in "${STRATUM0_SERVERS[@]}"; do
            print_info "  $i. $server"
            i=$((i+1))
        done
    else
        print_warning "No Stratum 0 servers found or specified. Synchronization check will be skipped."
        print_info "  To manually specify Stratum 0 servers, use the -s option: -s stratum0.example.org"
    fi
    
    return 0
}

# Check synchronization between Stratum 0 and Stratum 1
check_stratum0_sync() {
    print_header "Stratum 0 Synchronization Status"
    
    # If no Stratum 0 servers are available, skip this check
    if [ ${#STRATUM0_SERVERS[@]} -eq 0 ]; then
        print_warning "No Stratum 0 servers available, skipping synchronization check"
        print_info "  To check Stratum 0 sync, use the -s option: -s stratum0.example.org"
        return 0
    fi
    
    # Get local information from current Stratum 1
    local local_revision=""
    local local_timestamp=""
    local local_root_hash=""
    local timestamp_raw=""
    
    # Try to get local repository information
    local repo_path="$CVMFS_BASE/$REPO"
    
    if [ ! -d "$repo_path" ]; then
        print_error "Repository not found: $repo_path"
        return 1
    fi
    
    # Try to get info from cvmfs_server first
    if command -v cvmfs_server &> /dev/null; then
        local catalog_info=$(cvmfs_server info "$REPO" 2>/dev/null)
        
        if [ $? -eq 0 ] && [ -n "$catalog_info" ]; then
            local_revision=$(echo "$catalog_info" | grep "Revision" | awk '{print $2}')
            local_timestamp=$(echo "$catalog_info" | grep "Last modified" | sed 's/Last modified: //')
            local_root_hash=$(echo "$catalog_info" | grep "Root catalog hash" | awk '{print $4}')
        fi
    fi
    
    # If cvmfs_server info didn't work, try to extract from .cvmfspublished file
    if [ -z "$local_revision" ] && [ -f "$repo_path/.cvmfspublished" ]; then
        print_info "Extracting information from .cvmfspublished file..."
        
        # Create a clean version of the file without null bytes
        local tmp_local_file=$(mktemp)
        tr -d '\000' < "$repo_path/.cvmfspublished" > "$tmp_local_file"
        
        # Extract revision
        local_revision=$(grep -a -o -E 'S[0-9a-f]{8}' "$tmp_local_file" 2>/dev/null | cut -c2- | head -1)
        if [ -z "$local_revision" ]; then
            local_revision=$(hexdump -n 20 -e '"%x"' "$tmp_local_file" 2>/dev/null | grep -o -E '[0-9a-f]{8}' | head -1)
        fi
        
        # Extract timestamp
        timestamp_raw=$(grep -a -o -E 'T[0-9]{10}' "$tmp_local_file" 2>/dev/null | cut -c2- | head -1)
        if [ -n "$timestamp_raw" ]; then
            local_timestamp=$(date -d "@$timestamp_raw" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "unknown")
        fi
        
        # Extract root hash
        local_root_hash=$(grep -a -o -E 'C[0-9a-f]{40}' "$tmp_local_file" 2>/dev/null | cut -c2- | head -1)
        
        # Clean up temporary file
        rm -f "$tmp_local_file"
    fi
    
    # Display local information
    if [ -n "$local_revision" ]; then
        print_info "Local repository information:"
        print_info "  • Revision: ${BOLD}$local_revision${RESET}"
        
        if [ -n "$local_timestamp" ]; then
            print_info "  • Last modified: ${BOLD}$local_timestamp${RESET}"
        fi
        
        if [ -n "$local_root_hash" ]; then
            print_info "  • Root hash: ${BOLD}$local_root_hash${RESET}"
        fi
    else
        print_warning "Could not determine local repository information"
        return 1
    fi
    
    # Create arrays to store results
    declare -a stratum0_names=()
    declare -a stratum0_revisions=()
    declare -a stratum0_timestamps=()
    declare -a stratum0_hashes=()
    declare -a stratum0_statuses=()
    
    # Check each Stratum 0 server
    local sync_count=0
    local latest_revision="$local_revision"
    local latest_timestamp="$timestamp_raw"
    local latest_server=""
    
    for server in "${STRATUM0_SERVERS[@]}"; do
        print_info "\nChecking Stratum 0 server: $server"
        
        # Fetch .cvmfspublished from Stratum 0
        local stratum0_published=$(curl -s --max-time 10 "http://$server/cvmfs/$REPO/.cvmfspublished" 2>/dev/null)
        
        if [ -z "$stratum0_published" ]; then
            print_error "  • Failed to connect to Stratum 0 server"
            print_info "    Check that $server is accessible and serves $REPO"
            
            # Record results
            stratum0_names+=("$server")
            stratum0_revisions+=("unknown")
            stratum0_timestamps+=("unknown")
            stratum0_hashes+=("unknown")
            stratum0_statuses+=("unreachable")
            
            continue
        fi
        
        # Extract Stratum 0 information
        # First save the file to a temporary location to avoid null byte issues
        local tmp_published_file=$(mktemp)
        curl -s --max-time 10 "http://$server/cvmfs/$REPO/.cvmfspublished" > "$tmp_published_file" 2>/dev/null
        
        # Extract revision using tr to remove any null bytes
        local stratum0_revision=$(tr -d '\000' < "$tmp_published_file" | grep -a -o -E 'S[0-9a-f]{8}' | cut -c2- | head -1)
        if [ -z "$stratum0_revision" ]; then
            # Alternative method
            stratum0_revision=$(tr -d '\000' < "$tmp_published_file" | hexdump -n 20 -e '"%x"' 2>/dev/null | grep -o -E '[0-9a-f]{8}' | head -1)
        fi
        
        local stratum0_timestamp="unknown"
        local stratum0_timestamp_raw=""
        local stratum0_timestamp_raw=$(tr -d '\000' < "$tmp_published_file" | grep -a -o -E 'T[0-9]{10}' | cut -c2- | head -1)
        if [ -n "$stratum0_timestamp_raw" ]; then
            stratum0_timestamp=$(date -d "@$stratum0_timestamp_raw" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "unknown")
        fi
        
        local stratum0_root_hash=$(tr -d '\000' < "$tmp_published_file" | grep -a -o -E 'C[0-9a-f]{40}' | cut -c2- | head -1)
        
        # Clean up temporary file
        rm -f "$tmp_published_file"
        
        # Display Stratum 0 information
        print_info "  • Revision: ${BOLD}$stratum0_revision${RESET}"
        
        if [ "$stratum0_timestamp" != "unknown" ]; then
            print_info "  • Last modified: ${BOLD}$stratum0_timestamp${RESET}"
        fi
        
        # Track the server with the latest revision
        if [ -n "$stratum0_timestamp_raw" ] && [ -n "$latest_timestamp" ]; then
            if [ "$stratum0_timestamp_raw" -gt "$latest_timestamp" ]; then
                latest_revision="$stratum0_revision"
                latest_timestamp="$stratum0_timestamp_raw"
                latest_server="$server"
            fi
        elif [ -z "$latest_timestamp" ] && [ -n "$stratum0_timestamp_raw" ]; then
            latest_revision="$stratum0_revision"
            latest_timestamp="$stratum0_timestamp_raw"
            latest_server="$server"
        fi
        
        # Check synchronization status
        local sync_status=""
        if [ "$local_revision" = "$stratum0_revision" ]; then
            print_success "  • Synchronized with local server"
            sync_status="synchronized"
            sync_count=$((sync_count + 1))
            
            # Check if root hash matches too (extra validation)
            if [ -n "$local_root_hash" ] && [ -n "$stratum0_root_hash" ] && [ "$local_root_hash" = "$stratum0_root_hash" ]; then
                print_success "  • Root hashes match"
            elif [ -n "$local_root_hash" ] && [ -n "$stratum0_root_hash" ]; then
                print_warning "  • Root hashes differ despite matching revisions!"
                sync_status="hash_mismatch"
            fi
        else
            print_warning "  • NOT synchronized with local server"
            sync_status="out_of_sync"
            
            # Try to determine which is newer
            if [ -n "$stratum0_timestamp_raw" ] && [ -n "$timestamp_raw" ]; then
                if [ "$stratum0_timestamp_raw" -gt "$timestamp_raw" ]; then
                    local time_diff=$((stratum0_timestamp_raw - timestamp_raw))
                    local hours=$((time_diff / 3600))
                    print_warning "  • Stratum 0 is ahead by approximately $hours hours"
                elif [ "$timestamp_raw" -gt "$stratum0_timestamp_raw" ]; then
                    local time_diff=$((timestamp_raw - stratum0_timestamp_raw))
                    local hours=$((time_diff / 3600))
                    print_warning "  • Local server is ahead by approximately $hours hours"
                    sync_status="ahead_of_stratum0"
                fi
            fi
        fi
        
        # Record results for this server
        stratum0_names+=("$server")
        stratum0_revisions+=("$stratum0_revision")
        stratum0_timestamps+=("$stratum0_timestamp")
        stratum0_hashes+=("$stratum0_root_hash")
        stratum0_statuses+=("$sync_status")
    done
    
    # Display summary
    print_info "\nSynchronization Summary:"
    if [ ${#STRATUM0_SERVERS[@]} -eq 0 ]; then
        print_warning "No Stratum 0 servers checked"
    elif [ $sync_count -eq ${#STRATUM0_SERVERS[@]} ]; then
        print_success "Synchronized with all ${#STRATUM0_SERVERS[@]} Stratum 0 servers"
    else
        print_warning "Synchronized with $sync_count out of ${#STRATUM0_SERVERS[@]} Stratum 0 servers"
        
        # If we found a server with a newer revision, suggest actions
        if [ -n "$latest_server" ] && [ "$latest_revision" != "$local_revision" ]; then
            print_info "\nLatest revision ($latest_revision) found on server: $latest_server"
            print_info "Current local revision: $local_revision"
            
            print_info "\nSuggested actions:"
            print_info "  • Check Stratum 1 server snapshot/replication schedule"
            print_info "  • Verify network connectivity to $latest_server"
            print_info "  • Check for errors in /var/log/cvmfs or systemd journal"
            print_info "  • Manually trigger replication with: cvmfs_server snapshot $REPO"
        fi
    fi
    
    # Save synchronization data
    for i in "${!stratum0_names[@]}"; do
        save_data "$DATA_DIR/hourly/stratum0_sync.csv" "$TIMESTAMP,$local_revision,${stratum0_revisions[$i]},$local_timestamp,${stratum0_timestamps[$i]},${stratum0_names[$i]},${stratum0_statuses[$i]}"
    done
    
    return 0
}

# Generate simple plots for the report
generate_plots() {
    print_header "Generating Plots"
    
    if ! command -v gnuplot &> /dev/null; then
        print_warning "gnuplot not found, skipping plot generation"
        return 1
    fi
    
    # Create plots directory
    ensure_dir "$DATA_DIR/plots"
    
    # Ensure the plots directory exists for web access
    local plots_web_dir="$(dirname "$OUTPUT_FILE")/metrics/plots"
    if [ -n "$OUTPUT_FILE" ]; then
        ensure_dir "$plots_web_dir"
    fi
    
    # Get current values for plots
    local repo_size=$(tail -1 "$DATA_DIR/daily/repo_size.csv" 2>/dev/null | cut -d, -f4 || echo "0")
    local num_files=$(tail -1 "$DATA_DIR/daily/repo_size.csv" 2>/dev/null | cut -d, -f5 || echo "0")
    local unique_clients=$(tail -1 "$DATA_DIR/hourly/apache_stats.csv" 2>/dev/null | cut -d, -f2 || echo "0")
    local total_requests=$(tail -1 "$DATA_DIR/hourly/apache_stats.csv" 2>/dev/null | cut -d, -f3 || echo "0")
    local hit_rate=$(tail -1 "$DATA_DIR/hourly/squid_stats.csv" 2>/dev/null | cut -d, -f5 || echo "0")
    
    # Create simple plots
    print_info "Creating repository size plot..."
    gnuplot << EOF
set terminal png size 800,400
set output "$DATA_DIR/plots/repo_size.png"
set title "Repository Size: $REPO"
set xlabel "Current Size"
set ylabel "GB"
set grid
set style fill solid 0.5
set boxwidth 0.5
set xrange [0:2]
unset xtics
set label "Current size: $repo_size GB" at screen 0.5, 0.5 center
set label "Total files: $num_files" at screen 0.5, 0.4 center
plot [-0.5:1.5] '-' using 1:2 with boxes notitle lc rgb "#3498db"
1 $repo_size
e
EOF
    
    # Copy to web directory if needed
    if [ -n "$OUTPUT_FILE" ]; then
        cp "$DATA_DIR/plots/repo_size.png" "$plots_web_dir/" 2>/dev/null
    fi
    
    print_info "Creating client connections plot..."
    gnuplot << EOF
set terminal png size 800,400
set output "$DATA_DIR/plots/clients.png"
set title "Client Connections: $REPO"
set grid
set style data histograms
set style fill solid 0.5
set boxwidth 0.8
set ylabel "Count"
set yrange [0:*]
set xtics rotate by -45
plot '-' using 2:xtic(1) with boxes notitle lc rgb "#2ecc71"
"Unique Clients" $unique_clients
"Total Requests" $total_requests
e
EOF
    
    # Copy to web directory if needed
    if [ -n "$OUTPUT_FILE" ]; then
        cp "$DATA_DIR/plots/clients.png" "$plots_web_dir/" 2>/dev/null
    fi
    
    print_info "Creating bandwidth and cache plots..."
    gnuplot << EOF
set terminal png size 800,400
set output "$DATA_DIR/plots/cache.png"
set title "Cache Performance: $REPO"
set grid
set style data histograms
set style fill solid 0.5
set boxwidth 0.8
set ylabel "Percentage"
set yrange [0:100]
set label "Current cache hit rate: $hit_rate%" at screen 0.5, 0.5 center
plot '-' using 2:xtic(1) with boxes notitle lc rgb "#e74c3c"
"Hit Rate" $hit_rate
e
EOF
    
    # Copy to web directory if needed
    if [ -n "$OUTPUT_FILE" ]; then
        cp "$DATA_DIR/plots/cache.png" "$plots_web_dir/" 2>/dev/null
    fi

    # Create a stratum0 sync plot if we have data
    if [ -f "$DATA_DIR/hourly/stratum0_sync.csv" ]; then
        print_info "Creating Stratum 0 synchronization plot..."
        
        # Get last sync status
        local local_rev=$(tail -1 "$DATA_DIR/hourly/stratum0_sync.csv" 2>/dev/null | cut -d, -f2 || echo "unknown")
        local stratum0_rev=$(tail -1 "$DATA_DIR/hourly/stratum0_sync.csv" 2>/dev/null | cut -d, -f3 || echo "unknown")
        local sync_status="Unknown"
        
        if [ "$local_rev" = "$stratum0_rev" ]; then
            sync_status="Synchronized"
        else
            sync_status="Out of sync"
        fi
        
        gnuplot << EOF
set terminal png size 800,400
set output "$DATA_DIR/plots/stratum0_sync.png"
set title "Stratum 0 Synchronization Status: $REPO"
set grid
set style fill solid 0.5
set boxwidth 0.5
set ylabel "Status"
set yrange [0:1.5]
set xrange [0:1.5]
unset xtics
unset ytics
set label "Stratum 0: $stratum0_rev" at screen 0.5, 0.6 center
set label "Stratum 1: $local_rev" at screen 0.5, 0.5 center
set label "Status: $sync_status" at screen 0.5, 0.4 center font ",14"
plot 1 using 1:(1) with boxes notitle lc rgb "$([ "$sync_status" = "Synchronized" ] && echo "#2ecc71" || echo "#e74c3c")"
EOF
        
        # Copy to web directory if needed
        if [ -n "$OUTPUT_FILE" ]; then
            cp "$DATA_DIR/plots/stratum0_sync.png" "$plots_web_dir/" 2>/dev/null
        fi
    fi
    
    print_success "Plots created successfully in $DATA_DIR/plots/"
    print_info "NOTE: With more data collection over time, plots will show trends automatically in future runs"
    
    return 0
}

# Generate HTML report
generate_report() {
    if [ -z "$OUTPUT_FILE" ]; then
        return 0
    fi
    
    print_header "Generating HTML Report"
    
    # Ensure output directory exists
    ensure_dir "$(dirname "$OUTPUT_FILE")"
    
    # Generate plots first
    generate_plots
    
    # Gather data for report
    local repo_size=$(tail -1 "$DATA_DIR/daily/repo_size.csv" 2>/dev/null | cut -d, -f4 || echo "Unknown")
    local num_files=$(tail -1 "$DATA_DIR/daily/repo_size.csv" 2>/dev/null | cut -d, -f5 || echo "Unknown")
    local revision=$(tail -1 "$DATA_DIR/hourly/catalog_stats.csv" 2>/dev/null | cut -d, -f2 || echo "Unknown")
    local unique_clients=$(tail -1 "$DATA_DIR/hourly/apache_stats.csv" 2>/dev/null | cut -d, -f2 || echo "0")
    local total_requests=$(tail -1 "$DATA_DIR/hourly/apache_stats.csv" 2>/dev/null | cut -d, -f3 || echo "0")
    local hit_rate=$(tail -1 "$DATA_DIR/hourly/squid_stats.csv" 2>/dev/null | cut -d, -f5 || echo "0")
    
    # Get stratum0 sync data if available
    local stratum0_status="Not checked"
    local local_rev=""
    local stratum0_rev=""
    
    if [ -f "$DATA_DIR/hourly/stratum0_sync.csv" ]; then
        local_rev=$(tail -1 "$DATA_DIR/hourly/stratum0_sync.csv" 2>/dev/null | cut -d, -f2 || echo "")
        stratum0_rev=$(tail -1 "$DATA_DIR/hourly/stratum0_sync.csv" 2>/dev/null | cut -d, -f3 || echo "")
        
        if [ -n "$local_rev" ] && [ -n "$stratum0_rev" ]; then
            if [ "$local_rev" = "$stratum0_rev" ]; then
                stratum0_status="Synchronized"
            else
                stratum0_status="Out of sync"
            fi
        fi
    fi
    
    # Create HTML report
    print_info "Writing HTML report to $OUTPUT_FILE..."
    
    # Create directory for plots
    ensure_dir "$(dirname "$OUTPUT_FILE")/metrics/plots"
    
    cat > "$OUTPUT_FILE" << EOF
<!DOCTYPE html>
<html>
<head>
    <title>EESSI Stratum 1 Monitoring Report</title>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
            line-height: 1.6;
            color: #333;
            max-width: 1200px;
            margin: 0 auto;
            padding: 20px;
        }
        h1, h2, h3 {
            color: #2c3e50;
        }
        .header {
            background-color: #3498db;
            color: white;
            padding: 20px;
            border-radius: 5px;
            margin-bottom: 30px;
        }
        .section {
            background-color: #f8f9fa;
            border-radius: 5px;
            padding: 20px;
            margin-bottom: 20px;
            box-shadow: 0 2px 5px rgba(0,0,0,0.1);
        }
        .metric {
            display: flex;
            align-items: center;
            margin-bottom: 10px;
        }
        .metric-label {
            width: 200px;
            font-weight: bold;
        }
        .metric-value {
            font-family: monospace;
        }
        .plots {
            display: flex;
            flex-wrap: wrap;
            justify-content: space-between;
        }
        .plot {
            flex: 0 0 48%;
            margin-bottom: 20px;
        }
        .alert {
            background-color: #f8d7da;
            color: #721c24;
            padding: 10px;
            border-radius: 5px;
            margin-bottom: 10px;
        }
        .success {
            background-color: #d4edda;
            color: #155724;
            padding: 10px;
            border-radius: 5px;
            margin-bottom: 10px;
        }
        @media (max-width: 768px) {
            .plot {
                flex: 0 0 100%;
            }
        }
        table {
            width: 100%;
            border-collapse: collapse;
            margin-bottom: 20px;
        }
        th, td {
            padding: 8px;
            text-align: left;
            border-bottom: 1px solid #ddd;
        }
        th {
            background-color: #f2f2f2;
        }
        .status-badge {
            display: inline-block;
            padding: 4px 8px;
            border-radius: 4px;
            font-weight: bold;
        }
        .status-success {
            background-color: #d4edda;
            color: #155724;
        }
        .status-warning {
            background-color: #fff3cd;
            color: #856404;
        }
        .status-danger {
            background-color: #f8d7da;
            color: #721c24;
        }
    </style>
</head>
<body>
    <div class="header">
        <h1>EESSI Stratum 1 Monitoring Report</h1>
        <p>Repository: $REPO</p>
        <p>Report generated on $TIMESTAMP</p>
    </div>
    
    <div class="section">
        <h2>Repository Summary</h2>
        <div class="metric">
            <div class="metric-label">Size:</div>
            <div class="metric-value">$repo_size GB</div>
        </div>
        <div class="metric">
            <div class="metric-label">Total Files:</div>
            <div class="metric-value">$num_files</div>
        </div>
        <div class="metric">
            <div class="metric-label">Revision:</div>
            <div class="metric-value">$revision</div>
        </div>
    </div>
    
    <div class="section">
        <h2>Client Activity</h2>
        <div class="metric">
            <div class="metric-label">Unique Clients:</div>
            <div class="metric-value">$unique_clients</div>
        </div>
        <div class="metric">
            <div class="metric-label">Total Requests:</div>
            <div class="metric-value">$total_requests</div>
        </div>
        <div class="metric">
            <div class="metric-label">Cache Hit Rate:</div>
            <div class="metric-value">$hit_rate%</div>
        </div>
    </div>
EOF

    # Add Stratum 0 sync section if available
    if [ -f "$DATA_DIR/hourly/stratum0_sync.csv" ] && [ ${#STRATUM0_SERVERS[@]} -gt 0 ]; then
        # Count synchronized and out-of-sync servers
        local sync_count=0
        local out_of_sync=0
        local unreachable=0
        local total_servers=0
        
        # Process sync data for all servers
        while IFS=, read -r timestamp local_rev stratum0_rev local_ts stratum0_ts server status || [ -n "$timestamp" ]; do
            if [[ "$timestamp" == "$TIMESTAMP"* ]]; then
                total_servers=$((total_servers + 1))
                if [ "$status" = "synchronized" ]; then
                    sync_count=$((sync_count + 1))
                elif [ "$status" = "unreachable" ]; then
                    unreachable=$((unreachable + 1))
                else
                    out_of_sync=$((out_of_sync + 1))
                fi
            fi
        done < "$DATA_DIR/hourly/stratum0_sync.csv"
        
        # Determine overall status
        local stratum0_status="Not checked"
        local status_class="status-warning"
        
        if [ $total_servers -gt 0 ]; then
            if [ $sync_count -eq $total_servers ]; then
                stratum0_status="Synchronized with all servers"
                status_class="status-success"
            elif [ $sync_count -gt 0 ]; then
                stratum0_status="Partially synchronized ($sync_count/$total_servers)"
                status_class="status-warning"
            else
                stratum0_status="Not synchronized with any server"
                status_class="status-danger"
            fi
        fi
        
        # Start the Stratum 0 section
        cat >> "$OUTPUT_FILE" << EOF
    <div class="section">
        <h2>Stratum 0 Synchronization</h2>
        <div class="metric">
            <div class="metric-label">Overall Status:</div>
            <div class="metric-value">
                <span class="status-badge $status_class">$stratum0_status</span>
            </div>
        </div>
        <div class="metric">
            <div class="metric-label">Stratum 1 Revision:</div>
            <div class="metric-value">$local_rev</div>
        </div>
EOF

        # Add server table
        cat >> "$OUTPUT_FILE" << EOF
        <h3>Stratum 0 Servers</h3>
        <table>
            <tr>
                <th>Server</th>
                <th>Revision</th>
                <th>Last Modified</th>
                <th>Status</th>
            </tr>
EOF

        # Add each server's status
        while IFS=, read -r timestamp local_rev stratum0_rev local_ts stratum0_ts server status || [ -n "$timestamp" ]; do
            if [[ "$timestamp" == "$TIMESTAMP"* ]]; then
                # Determine status class
                local server_status_class="status-warning"
                local status_text="Unknown"
                
                if [ "$status" = "synchronized" ]; then
                    server_status_class="status-success"
                    status_text="Synchronized"
                elif [ "$status" = "out_of_sync" ]; then
                    server_status_class="status-danger"
                    status_text="Out of sync"
                elif [ "$status" = "unreachable" ]; then
                    server_status_class="status-danger"
                    status_text="Unreachable"
                elif [ "$status" = "hash_mismatch" ]; then
                    server_status_class="status-warning"
                    status_text="Hash mismatch"
                elif [ "$status" = "ahead_of_stratum0" ]; then
                    server_status_class="status-warning"
                    status_text="Ahead of Stratum 0"
                fi
                
                cat >> "$OUTPUT_FILE" << EOF
            <tr>
                <td>$server</td>
                <td>$stratum0_rev</td>
                <td>$stratum0_ts</td>
                <td><span class="status-badge $server_status_class">$status_text</span></td>
            </tr>
EOF
            fi
        done < "$DATA_DIR/hourly/stratum0_sync.csv"

        # Close the table and section
        cat >> "$OUTPUT_FILE" << EOF
        </table>
    </div>
EOF
    fi
    
    # Continue with the rest of the report
    cat >> "$OUTPUT_FILE" << EOF
    <div class="section">
        <h2>Visualization</h2>
        <div class="plots">
            <div class="plot">
                <h3>Repository Size</h3>
                <img src="metrics/plots/repo_size.png" alt="Repository Size" style="max-width:100%;">
            </div>
            <div class="plot">
                <h3>Client Connections</h3>
                <img src="metrics/plots/clients.png" alt="Client Connections" style="max-width:100%;">
            </div>
EOF

    # Add Stratum 0 sync plot if available
    if [ -f "$DATA_DIR/plots/stratum0_sync.png" ]; then
        cat >> "$OUTPUT_FILE" << EOF
            <div class="plot">
                <h3>Stratum 0 Synchronization</h3>
                <img src="metrics/plots/stratum0_sync.png" alt="Stratum 0 Sync" style="max-width:100%;">
            </div>
EOF
    fi

    # Continue with the rest of the report
    cat >> "$OUTPUT_FILE" << EOF
        </div>
    </div>
    
    <div class="section">
        <h2>System Health</h2>
        <table>
            <tr>
                <th>Component</th>
                <th>Status</th>
            </tr>
            <tr>
                <td>Web Server</td>
                <td>$(systemctl is-active httpd &>/dev/null || systemctl is-active apache2 &>/dev/null && echo "Running" || echo "Not Running")</td>
            </tr>
            <tr>
                <td>Squid Proxy</td>
                <td>$(systemctl is-active squid &>/dev/null || systemctl is-active squid3 &>/dev/null && echo "Running" || echo "Not Running")</td>
            </tr>
            <tr>
                <td>Repository Access</td>
                <td>$(curl --silent --head --fail "http://$(hostname -f)/cvmfs/$REPO/.cvmfspublished" &>/dev/null && echo "Accessible" || echo "Not Accessible")</td>
            </tr>
            <tr>
                <td>Stratum 0 Sync</td>
                <td>$stratum0_status</td>
            </tr>
        </table>
    </div>
    
    <footer style="text-align: center; margin-top: 50px; color: #777;">
        <p>Generated by EESSI Stratum 1 Monitoring Script</p>
    </footer>
</body>
</html>
EOF
    
    print_success "HTML report generated: $OUTPUT_FILE"
    
    # Send email if requested
    if [ -n "$EMAIL" ]; then
        print_info "Sending report to $EMAIL..."
        
        if command -v mail &> /dev/null; then
            echo "EESSI Stratum 1 Monitoring Report" | mail -s "EESSI Stratum 1 Report - $DATE_SHORT" -a "$OUTPUT_FILE" "$EMAIL"
            
            if [ $? -eq 0 ]; then
                print_success "Email sent successfully"
            else
                print_error "Failed to send email"
            fi
        else
            print_warning "mail command not found - cannot send email"
        fi
    fi
    
    return 0
}

# ======================
# Main execution
# ======================

# Print welcome message
echo -e "${BOLD}${BLUE}==============================================${RESET}"
echo -e "${BOLD}${BLUE}  EESSI Stratum 1 Server Monitoring Tool      ${RESET}"
echo -e "${BOLD}${BLUE}==============================================${RESET}"
echo
echo -e "Starting monitoring for repository: ${BOLD}$REPO${RESET}"
echo -e "Time: $TIMESTAMP"
echo

# Ensure required directories exist
ensure_dir "$DATA_DIR"
ensure_dir "$DATA_DIR/daily"
ensure_dir "$DATA_DIR/hourly"

# Run checks
check_repo_size
check_catalog
check_web_server
check_squid
check_disk_space
discover_stratum0_servers  # First discover available Stratum 0 servers
check_stratum0_sync        # Then check sync with those servers

# Generate report if requested
if [ -n "$OUTPUT_FILE" ]; then
    generate_report
fi

# Print summary
print_header "Monitoring Summary"
echo -e "Repository: ${BOLD}$REPO${RESET}"
echo -e "Data saved to: ${BOLD}$DATA_DIR${RESET}"

if [ -n "$OUTPUT_FILE" ]; then
    echo -e "HTML report: ${BOLD}$OUTPUT_FILE${RESET}"
fi

# Show Stratum 0 synchronization summary
if [ ${#STRATUM0_SERVERS[@]} -gt 0 ] && [ -f "$DATA_DIR/hourly/stratum0_sync.csv" ]; then
    echo
    echo -e "Stratum 0 Synchronization Summary:"
    
    # Count synchronized and out-of-sync servers
    sync_count=0
    out_of_sync=0
    unreachable=0
    
    while IFS=, read -r timestamp local_rev stratum0_rev local_ts stratum0_ts server status || [ -n "$timestamp" ]; do
        if [ "$status" = "synchronized" ]; then
            sync_count=$((sync_count + 1))
        elif [ "$status" = "unreachable" ]; then
            unreachable=$((unreachable + 1))
        else
            out_of_sync=$((out_of_sync + 1))
        fi
    done < <(grep "^$TIMESTAMP" "$DATA_DIR/hourly/stratum0_sync.csv")
    
    total=$((sync_count + out_of_sync + unreachable))
    
    if [ $sync_count -eq $total ]; then
        echo -e "  ${GREEN}✓ Synchronized with all $total Stratum 0 servers${RESET}"
    elif [ $sync_count -gt 0 ]; then
        echo -e "  ${YELLOW}⚠ Synchronized with $sync_count of $total Stratum 0 servers${RESET}"
        
        if [ $out_of_sync -gt 0 ]; then
            echo -e "    • $out_of_sync servers out of sync"
        fi
        
        if [ $unreachable -gt 0 ]; then
            echo -e "    • $unreachable servers unreachable"
        fi
    elif [ $total -gt 0 ]; then
        echo -e "  ${RED}✗ Not synchronized with any Stratum 0 servers${RESET}"
        
        if [ $out_of_sync -gt 0 ]; then
            echo -e "    • $out_of_sync servers out of sync"
        fi
        
      l  if [ $unreachable -gt 0 ]; then
            echo -e "    • $unreachable servers unreachable"
        fi
    fi
fi

echo
echo -e "${BOLD}${BLUE}Monitoring completed successfully${RESET}"
echo

exit 0
