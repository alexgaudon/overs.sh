#!/bin/bash

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Global variables
DOMAIN=""

log() {
    echo -e "${BLUE}[DEPLOY]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

usage() {
    echo "Usage: $0 <domain>"
    echo "Example: $0 example.com"
    echo "Example: $0 overssh.mydomain.com"
    exit 1
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
        exit 1
    fi
}

validate_domain() {
    if [ -z "$1" ]; then
        error "Domain is required"
        usage
    fi
    
    # Basic domain validation
    if [[ ! "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        error "Invalid domain format: $1"
        exit 1
    fi
    
    DOMAIN="$1"
    success "Domain validated: $DOMAIN"
}

backup_ssh_config() {
    log "Backing up SSH configuration..."
    if [ -f /etc/ssh/sshd_config ]; then
        cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup.$(date +%Y%m%d_%H%M%S)
        success "SSH config backed up"
    fi
}

install_docker() {
    log "Installing Docker..."
    if ! command -v docker &> /dev/null; then
        # Update package database
        apt-get update
        
        # Install required packages
        apt-get install -y \
            ca-certificates \
            curl \
            gnupg \
            lsb-release
        
        # Add Docker's official GPG key
        mkdir -p /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        
        # Set up the repository
        echo \
          "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
          $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
        
        # Install Docker Engine
        apt-get update
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
        
        # Enable and start Docker
        systemctl enable docker
        systemctl start docker
        
        success "Docker installed successfully"
    else
        log "Docker already installed"
    fi
}

remap_ssh_port() {
    log "Remapping system SSH from port 22 to 2222..."
    
    # Check if SSH is already on port 2222
    if grep -q "^Port 2222" /etc/ssh/sshd_config; then
        warn "SSH already configured on port 2222"
        return
    fi
    
    # Update SSH configuration
    if grep -q "^#Port 22" /etc/ssh/sshd_config; then
        sed -i 's/^#Port 22/Port 2222/' /etc/ssh/sshd_config
    elif grep -q "^Port 22" /etc/ssh/sshd_config; then
        sed -i 's/^Port 22/Port 2222/' /etc/ssh/sshd_config
    else
        echo "Port 2222" >> /etc/ssh/sshd_config
    fi
    
    # Test SSH configuration
    sshd -t
    if [ $? -eq 0 ]; then
        success "SSH configuration is valid"
    else
        error "SSH configuration is invalid"
        exit 1
    fi
    
    warn "SSH will be moved to port 2222 after restart. Make sure you can connect on the new port!"
    warn "To connect after deployment: ssh -p 2222 user@server"
}

create_overssh_service() {
    log "Creating OverSSH systemd service..."
    
    # Use /root as the working directory for consistent deployment
    OVERSSH_DIR="/root/overssh"
    mkdir -p "$OVERSSH_DIR"
    
    cat > /etc/systemd/system/overssh.service << EOF
[Unit]
Description=OverSSH Docker Service
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$OVERSSH_DIR
ExecStart=/usr/bin/docker compose -f docker-compose.prod.yml up -d
ExecStop=/usr/bin/docker compose -f docker-compose.prod.yml down
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable overssh.service
    success "OverSSH service created and enabled"
}

download_caddyfile() {
    log "Downloading and configuring Caddyfile from GitHub..."
    
    # Ensure the directory exists and download to the correct location
    OVERSSH_DIR="/root/overssh"
    
    # Download the Caddyfile from GitHub
    curl -fsSL https://raw.githubusercontent.com/alexgaudon/overs.sh/main/Caddyfile -o "$OVERSSH_DIR/Caddyfile.template"
    
    if [ $? -eq 0 ]; then
        # Replace the domain placeholder with the actual domain
        sed "s/{\$DOMAIN:localhost}/$DOMAIN/g" "$OVERSSH_DIR/Caddyfile.template" > "$OVERSSH_DIR/Caddyfile"
        
        # Remove the template file
        rm "$OVERSSH_DIR/Caddyfile.template"
        
        success "Caddyfile configured with domain: $DOMAIN"
    else
        error "Failed to download Caddyfile from GitHub"
        exit 1
    fi
}

download_docker_compose() {
    log "Downloading docker-compose.prod.yml from GitHub..."
    
    # Ensure the directory exists and download to the correct location
    OVERSSH_DIR="/root/overssh"
    
    # Download the production docker-compose file from GitHub
    curl -fsSL https://raw.githubusercontent.com/alexgaudon/overs.sh/main/docker-compose.prod.yml -o "$OVERSSH_DIR/docker-compose.prod.yml"
    
    if [ $? -eq 0 ]; then
        success "docker-compose.prod.yml downloaded successfully to $OVERSSH_DIR"
    else
        error "Failed to download docker-compose.prod.yml from GitHub"
        exit 1
    fi
}

generate_ssh_keys() {
    log "Generating SSH host keys for OverSSH..."
    
    OVERSSH_DIR="/root/overssh"
    
    # Generate SSH host key if it doesn't exist
    if [ ! -f "$OVERSSH_DIR/ssh_host_rsa_key" ]; then
        ssh-keygen -f "$OVERSSH_DIR/ssh_host_rsa_key" -N '' -t rsa -b 4096
        success "SSH host key generated"
    else
        log "SSH host key already exists"
    fi
    
    # Set proper permissions
    chmod 600 "$OVERSSH_DIR/ssh_host_rsa_key"
    chmod 644 "$OVERSSH_DIR/ssh_host_rsa_key.pub"
}

setup_firewall() {
    log "Configuring firewall..."
    
    if command -v ufw &> /dev/null; then
        # Allow new SSH port
        ufw allow 2222/tcp comment 'SSH'
        
        # Allow OverSSH port
        ufw allow 22/tcp comment 'OverSSH'
        
        # Allow HTTP port (for Caddy)
        ufw allow 80/tcp comment 'HTTP'
        
        # Allow HTTPS port (for Caddy SSL)
        ufw allow 443/tcp comment 'HTTPS'
        
        success "Firewall rules updated"
    else
        warn "ufw not found, skipping firewall configuration"
    fi
}

deploy_application() {
    log "Building and deploying OverSSH application..."
    
    # Change to the correct directory and pull images
    OVERSSH_DIR="/root/overssh"
    cd "$OVERSSH_DIR"
    
    # Create environment file with domain
    echo "DOMAIN=$DOMAIN" > .env
    echo "URL=https://$DOMAIN" >> .env
    
    # Build the application (production uses pre-built image)
    docker compose -f docker-compose.prod.yml pull
    
    # Start the service
    systemctl start overssh.service
    
    success "OverSSH application deployed and started"
}

restart_services() {
    log "Restarting services..."
    
    warn "Restarting SSH service - you may be disconnected!"
    sleep 2
    
    # Restart SSH service
    systemctl restart ssh
    
    # Start OverSSH service
    systemctl start overssh.service
    
    success "Services restarted"
}

show_status() {
    log "Deployment status:"
    echo
    echo "SSH Service (port 2222):"
    systemctl status ssh --no-pager -l
    echo
    echo "OverSSH Service (port 22):"
    systemctl status overssh --no-pager -l
    echo
    echo "Docker containers:"
    docker ps
    echo
    success "Deployment completed!"
    warn "System SSH is now on port 2222"
    warn "OverSSH is now running on port 22"
    success "Web interface available at: https://$DOMAIN"
    warn "SSL certificate will be automatically obtained by Caddy"
}

main() {
    log "Starting OverSSH deployment..."
    
    # Validate arguments
    if [ $# -ne 1 ]; then
        usage
    fi
    
    validate_domain "$1"
    check_root
    backup_ssh_config
    install_docker
    remap_ssh_port
    setup_firewall
    create_overssh_service
    download_caddyfile
    download_docker_compose
    generate_ssh_keys
    deploy_application
    restart_services
    show_status
    
    success "OverSSH deployment completed successfully!"
}

# Handle script interruption
trap 'error "Deployment interrupted"; exit 1' INT TERM

# Run main function
main "$@"