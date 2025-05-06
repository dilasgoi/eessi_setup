# EESSI Setup Project

A comprehensive toolkit for setting up and maintaining EESSI (European Environment for Scientific Software Installations) infrastructure, including Stratum 1 server deployment, client configuration, and monitoring tools.

## Overview

The EESSI Setup Project provides a set of scripts and tools to:

1. **Deploy EESSI Stratum 1 servers** - Create and maintain local CVMFS replicas of the EESSI software repository
2. **Configure EESSI clients** - Easily set up workstations and compute nodes to access EESSI software
3. **Monitor EESSI infrastructure** - Track performance, synchronization status, and health of EESSI components
4. **Integrate with HPC environments** - Environment modules and system services for seamless EESSI integration

EESSI (pronounced "easy") provides a shared repository of scientific software installations that can be used across different Linux distributions and processor architectures, from laptops to HPC clusters.

## Project Structure

```
.
├── client
│   ├── bin
│   │   ├── eessi_client_setup.sh      # Client installation script
│   │   └── eessi_diagnostics.sh       # Client diagnostics utility
│   ├── modules
│   │   └── EESSI-2023.06.lua          # Example Lmod module file
│   └── systemd
│       └── eessi-mount.service        # Systemd service for auto-mounting
├── README.md                          # Main project documentation
└── stratum1
    └── bin
        ├── eessi_stratum1_monitoring.sh  # Monitoring utility
        └── eessi_stratum1_setup.sh       # Stratum 1 deployment script
```

## What is EESSI?

The European Environment for Scientific Software Installations (EESSI) is a collaborative project that provides a common stack of scientific software for HPC systems and other computing environments. EESSI works like a streaming service for scientific software, making it available on demand across different platforms.

Key features:
- **Compatible across systems** - Works on various Linux distributions and processor architectures
- **Optimized for performance** - Software is built with architecture-specific optimizations
- **Easy to deploy and use** - Minimal system requirements and straightforward configuration
- **Community-maintained** - Developed and maintained by HPC centers across Europe

EESSI uses the CernVM File System (CVMFS) for efficient distribution of software.

## CVMFS Architecture and EESSI

EESSI is built on the CernVM File System (CVMFS), which provides a reliable and scalable software distribution system. The architecture consists of:

- **Stratum 0 Server** - The central repository where software is published
- **Stratum 1 Servers** - Distribution points that replicate content from Stratum 0
- **CVMFS Clients** - End-user systems that mount the repositories

In this architecture:
1. Software is published to the Stratum 0 server
2. Stratum 1 servers periodically synchronize with Stratum 0
3. Clients connect to Stratum 1 servers to access software
4. Local caching ensures efficient access to frequently used content

## Stratum 1 Server Setup and Management

### Prerequisites

- A Linux server with at least 4GB RAM and sufficient storage (recommend 500GB+)
- Root or sudo access
- Network connectivity to the internet and to client machines
- Open port: 80 (HTTP)

### Basic Installation

```bash
sudo stratum1/bin/eessi_stratum1_setup.sh
```

This script will:
1. Install required dependencies (Ansible, CVMFS, Apache, Squid)
2. Clone the EESSI filesystem-layer repository
3. Configure the server as a Stratum 1 replica
4. Set up the web server and Squid proxy
5. Verify the installation

### Advanced Installation Options

The `eessi_stratum1_setup.sh` script accepts several variables to customize the deployment:

```bash
# Use custom storage location
CUSTOM_STORAGE_DIR="/data/cvmfs" sudo stratum1/bin/eessi_stratum1_setup.sh

# Enable GeoAPI for geographic-based client redirection
USE_GEOAPI="yes" sudo stratum1/bin/eessi_stratum1_setup.sh

# Specify the repository to replicate
REPOSITORY="software.eessi.io" sudo stratum1/bin/eessi_stratum1_setup.sh
```

### Stratum 1 Monitoring

The `eessi_stratum1_monitoring.sh` script provides comprehensive monitoring for EESSI Stratum 1 servers.

Basic usage:
```bash
sudo stratum1/bin/eessi_stratum1_monitoring.sh
```

This will:
1. Check repository size and content
2. Monitor catalog information
3. Analyze web server and client connections
4. Monitor disk space usage
5. Check synchronization with Stratum 0

Advanced options:
```bash
# Generate HTML report
sudo stratum1/bin/eessi_stratum1_monitoring.sh -o /var/www/html/eessi-report.html

# Generate report and email it
sudo stratum1/bin/eessi_stratum1_monitoring.sh -o /var/www/html/eessi-report.html -e admin@example.org

# Check against specific Stratum 0 server
sudo stratum1/bin/eessi_stratum1_monitoring.sh -s cvmfs-stratum0.example.org
```

For automated monitoring, set up a cron job:
```bash
# Create a cron job to run every hour
echo "0 * * * * root /path/to/stratum1/bin/eessi_stratum1_monitoring.sh -o /var/www/html/eessi-report.html" | sudo tee /etc/cron.d/eessi-monitoring
```

### Stratum 1 Maintenance

#### Updating Repository Content

To manually trigger synchronization:
```bash
sudo cvmfs_server snapshot software.eessi.io
```

To synchronize all repositories:
```bash
sudo cvmfs_server snapshot -a
```

#### Storage Management

The default storage location for CVMFS repositories is `/srv/cvmfs`. If storage space is running low:

1. Check current usage:
   ```bash
   df -h /srv/cvmfs
   ```

2. Garbage collection runs automatically with each snapshot, but can be manually triggered:
   ```bash
   sudo cvmfs_server gc software.eessi.io
   ```

#### Performance Tuning

For Stratum 1 servers with high load:

1. Adjust Apache configuration:
   - Increase `MaxClients` in Apache configuration
   - Consider using the "worker" or "event" MPM instead of "prefork"

2. Optimize file system performance:
   - Consider using SSD storage for repository data
   - Adjust file system mount options for better performance

### Stratum 1 Troubleshooting

#### Common Issues

1. **Synchronization failures**
   - Check network connectivity to Stratum 0 servers
   - Verify that Stratum 0 servers are accessible
   - Check for errors in `/var/log/cvmfs` or systemd journal

2. **Web server issues**
   - Verify Apache configuration: `sudo apachectl configtest`
   - Check Apache logs: `/var/log/httpd/error_log` or `/var/log/apache2/error.log`
   - Restart Apache: `sudo systemctl restart httpd` or `sudo systemctl restart apache2`

3. **Storage issues**
   - Ensure sufficient disk space for repository growth
   - Check file system for errors: `sudo fsck /dev/sdXY`
   - Monitor I/O performance: `sudo iotop`

#### Diagnostic Tools

1. Check repository status:
   ```bash
   sudo cvmfs_server info software.eessi.io
   ```

2. Check server health:
   ```bash
   sudo cvmfs_server check software.eessi.io
   ```

3. Verify web server configuration:
   ```bash
   curl -I http://localhost/cvmfs/software.eessi.io/.cvmfspublished
   ```

## Client Setup and Management

### Prerequisites

- Linux operating system (RHEL/CentOS/Rocky/Fedora or Debian/Ubuntu)
- Root or sudo access
- Network connectivity to EESSI Stratum 1 servers

### Basic Installation

```bash
sudo client/bin/eessi_client_setup.sh
```

This will:
1. Install CVMFS and the EESSI configuration
2. Configure CVMFS for accessing EESSI repositories
3. Test the connection to the EESSI repositories
4. Display available EESSI versions

### Advanced Installation Options

The script accepts several environment variables to customize the installation:

```bash
# Use a specific Stratum 1 server
EESSI_STRATUM1_IP=10.1.12.5 sudo -E client/bin/eessi_client_setup.sh

# Configure a larger cache size (in MB)
EESSI_CACHE_SIZE=20000 sudo -E client/bin/eessi_client_setup.sh

# Use a custom cache location
EESSI_CACHE_BASE=/data/cvmfs-cache sudo -E client/bin/eessi_client_setup.sh

# Specify a custom log file
EESSI_LOG_FILE=/var/log/eessi-client.log sudo -E client/bin/eessi_client_setup.sh

# Combine multiple options
EESSI_STRATUM1_IP=10.1.12.5 EESSI_CACHE_SIZE=20000 sudo -E client/bin/eessi_client_setup.sh
```

### Automatic Mounting at Boot

To ensure EESSI repositories are properly mounted when the system boots:

```bash
# Copy the service file
sudo cp client/systemd/eessi-mount.service /etc/systemd/system/

# Enable and start the service
sudo systemctl enable eessi-mount.service
sudo systemctl start eessi-mount.service
```

### Using EESSI Software

After installation, there are two main ways to access EESSI software:

#### Direct Initialization

```bash
source /cvmfs/software.eessi.io/versions/2023.06/init/bash
```

This will initialize the EESSI environment for the current shell session, making all EESSI software available.

#### Using Environment Modules

If your system uses environment modules (such as Lmod), you can use the provided module file:

```bash
# Copy the module file to your modules directory
sudo mkdir -p /etc/modulefiles/eessi
sudo cp client/modules/EESSI-2023.06.lua /etc/modulefiles/eessi/2023.06.lua

# Load the EESSI module
module load eessi/2023.06

# List available software
module avail

# Load specific software
module load Python/3.9.6
```

### Client Diagnostics and Troubleshooting

If you encounter issues with the EESSI client, the `eessi_diagnostics.sh` script can help identify and resolve common problems:

```bash
sudo client/bin/eessi_diagnostics.sh
```

#### Common Issues

1. **Repository accessibility**
   - Check if the CVMFS client service is running: `systemctl status autofs`
   - Verify network connectivity to the configured Stratum 1 servers
   - Test direct repository access: `cvmfs_config probe software.eessi.io`

2. **Cache issues**
   - Ensure sufficient disk space for the cache
   - Check cache permissions: `ls -la $EESSI_CACHE_BASE`
   - Reset the cache if corrupted: `cvmfs_talk -i software.eessi.io cleanup 0`

3. **Performance issues**
   - Consider using a local Stratum 1 server for better performance
   - Adjust cache size based on your usage patterns
   - Ensure client has adequate RAM and network bandwidth

### Advanced Client Configuration

#### Custom Domain Configuration

For environments with their own EESSI mirror servers, create or modify `/etc/cvmfs/domain.d/eessi.io.local`:

```bash
CVMFS_SERVER_URL="http://your-local-mirror.example.org/cvmfs/@fqrn@;${CVMFS_SERVER_URL}"
CVMFS_USE_GEOAPI=no
```

#### Direct Connection Configuration

To ensure clients connect directly to Stratum 1 servers without any intermediate proxy:

```bash
echo 'CVMFS_HTTP_PROXY="DIRECT"' | sudo tee -a /etc/cvmfs/default.local
sudo cvmfs_config reload
```

## Complete Deployment Example

This example demonstrates a full setup with a local Stratum 1 server and multiple clients.

### Step 1: Deploy the Stratum 1 Server

```bash
# On the Stratum 1 server (e.g., 10.0.0.1)
git clone https://github.com/yourusername/eessi-setup.git
cd eessi-setup
sudo stratum1/bin/eessi_stratum1_setup.sh

# Verify installation
curl --head http://localhost/cvmfs/software.eessi.io/.cvmfspublished

# Set up monitoring
sudo stratum1/bin/eessi_stratum1_monitoring.sh -o /var/www/html/eessi-report.html
echo "0 * * * * root $(pwd)/stratum1/bin/eessi_stratum1_monitoring.sh -o /var/www/html/eessi-report.html" | sudo tee /etc/cron.d/eessi-monitoring
```

### Step 2: Deploy Clients

```bash
# On each client
git clone https://github.com/yourusername/eessi-setup.git
cd eessi-setup

# Configure with the local Stratum 1 server
EESSI_STRATUM1_IP=10.0.0.1 sudo -E client/bin/eessi_client_setup.sh

# Set up auto-mounting
sudo cp client/systemd/eessi-mount.service /etc/systemd/system/
sudo systemctl enable eessi-mount.service
sudo systemctl start eessi-mount.service

# Set up environment module
sudo mkdir -p /etc/modulefiles/eessi
sudo cp client/modules/EESSI-2023.06.lua /etc/modulefiles/eessi/2023.06.lua
```

### Step 3: Test the Setup

```bash
# On each client, test EESSI repository access
cvmfs_config probe software.eessi.io

# Test software access via direct initialization
source /cvmfs/software.eessi.io/versions/2023.06/init/bash
python3 --version  # Example of using EESSI-provided software

# Test via environment modules
module load eessi/2023.06
module avail  # Should show available EESSI software
```

## Contributing

Contributions to the EESSI Setup Project are welcome! Please feel free to submit a Pull Request or open an Issue on GitHub.

## License

This project is licensed under the GNU General Public License v3.0 - see the LICENSE file for details.

## Acknowledgments

- The EESSI project: https://www.eessi.io/
- CernVM-FS: https://cernvm.cern.ch/fs/
- The European HPC community for their ongoing support and contributions

## Additional Resources

- [EESSI Documentation](https://eessi.github.io/docs/)
- [CVMFS Documentation](https://cvmfs.readthedocs.io/)
- [EESSI GitHub Organization](https://github.com/EESSI)
