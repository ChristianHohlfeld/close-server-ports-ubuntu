
# `close_server_ports.sh`

## Overview

`close_server_ports.sh` is a powerful Bash script designed to simplify the management of UFW (Uncomplicated Firewall) ports and Docker containers on Linux servers. This script allows users to view running Docker containers, identify open ports (both system and Docker-managed), and check their current status (inbound and outbound traffic). Additionally, it gives users the option to open or close ports with ease, enhancing both security and management.

The script automatically checks for the presence of Docker and Docker Compose, enabling advanced functionalities if they are available. It also parses UFW rules to determine which ports are allowed or denied and provides an interactive prompt to modify these rules.

## Features

- **Docker Container Management:** Lists all running Docker containers with detailed information, including port mappings.
- **Port Status Monitoring:** Displays the status (Allowed/Denied) of all open ports, including system and Docker-specific ports.
- **Interactive Firewall Control:** Provides options to allow or deny inbound and outbound traffic for each port.
- **UFW Integration:** Automatically parses and updates UFW rules for both system and Docker-managed ports.
- **Proxy Container Identification:** Detects applications served through proxy containers (e.g., Nginx) with detailed information about proxied apps.
- **Automated Docker Compose Detection:** Automatically handles Docker Compose projects and lists services with exposed ports.

## Prerequisites

- **UFW (Uncomplicated Firewall):** Ensure UFW is installed and configured on your system.
- **Docker:** If you use Docker, the script will list running containers and manage their ports.
- **Docker Compose:** If Docker Compose is installed, the script will detect and list running Compose services.

## Installation

1. Clone the repository:
   ```bash
   git clone https://github.com/ChristianHohlfeld/close-server-ports-ubuntu.git
   ```

2. Navigate to the directory:
   ```bash
   cd close-server-ports-ubuntu
   ```

3. Make the script executable:
   ```bash
   chmod +x manage_ports.sh
   ```

4. Run the script with root privileges:
   ```bash
   sudo ./manage_ports.sh
   ```

## Usage

Upon running the script, you will be presented with a detailed list of open ports on your system, along with their current inbound and outbound statuses. For each port, you will be prompted to either:
- Allow inbound traffic
- Deny inbound traffic
- Make no changes

Similarly, the script will prompt you for outbound traffic control.

### Example Output:
```text
Port   Proto  Service                        In         Out        Description
-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
443    tcp    HTTPS                          Allowed    Allowed    Secure HTTP for encrypted web traffic (Docker: nginx-proxy)
80     tcp    HTTP                           Denied     Allowed    Hypertext Transfer Protocol for web traffic
...
```

### Available Commands:
- **Allow inbound or outbound traffic:** Select this option to open the port.
- **Deny inbound or outbound traffic:** Select this option to close the port.
- **Make no changes:** Skip modifying the rule for the port.

## SEO Keywords

To make this repository more discoverable, here are some SEO keywords:

- UFW port management
- Docker container port management
- Docker firewall script
- Manage firewall ports with UFW
- UFW Docker integration
- Docker Compose port control
- Linux firewall automation script
- Bash firewall control script
- Docker security with UFW
- Open and close UFW ports
- Interactive UFW firewall management
- Docker proxy container port management
- Linux firewall configuration
- Firewall port monitoring tool
- UFW port rule management

## License

This project is licensed under the MIT License.

