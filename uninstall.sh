#!/bin/bash

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${BLUE}[UNINSTALL]${NC} $1"
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

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
        exit 1
    fi
}

confirm_uninstall() {
    warn "This will:"
    warn "1. Stop and remove OverSSH service"
    warn "2. Restore SSH to port 22"
    warn "3. Clean up Docker containers and images"
    warn "4. Remove firewall rules"
    warn "5. You will be disconnected during SSH restart"
    echo
    read -p "Are you sure you want to proceed? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log "Uninstall cancelled"
        exit 0
    fi
}

stop_overssh_service() {
    log "Stopping OverSSH service..."
    
    if systemctl is-active --quiet overssh.service; then
        systemctl stop overssh.service
        success "OverSSH service stopped"
    else
        log "OverSSH service already stopped"
    fi
    
    if systemctl is-enabled --quiet overssh.service; then
        systemctl disable overssh.service
        success "OverSSH service disabled"
    fi
}

cleanup_docker() {
    log "Cleaning up Docker containers and images..."
    
    # Stop and remove containers
    if [ -f docker-compose.yml ]; then
        docker compose -f docker-compose.yml -f docker-compose.prod.yml down --rmi all --volumes --remove-orphans 2>/dev/null || true
        success "Docker containers and images removed"
    fi
    
    # Remove any lingering OverSSH containers
    docker ps -a --filter "name=overssh" --format "{{.ID}}" | xargs -r docker rm -f 2>/dev/null || true
    
    # Remove any lingering Caddy containers
    docker ps -a --filter "name=caddy" --format "{{.ID}}" | xargs -r docker rm -f 2>/dev/null || true
    
    # Remove OverSSH images
    docker images --filter "reference=*overssh*" --format "{{.ID}}" | xargs -r docker rmi -f 2>/dev/null || true
    
    # Remove Caddy images
    docker images --filter "reference=caddy*" --format "{{.ID}}" | xargs -r docker rmi -f 2>/dev/null || true
    
    # Remove volumes
    docker volume ls --filter "name=caddy" --format "{{.Name}}" | xargs -r docker volume rm 2>/dev/null || true
    
    success "Docker cleanup completed"
}

remove_systemd_service() {
    log "Removing OverSSH systemd service..."
    
    if [ -f /etc/systemd/system/overssh.service ]; then
        rm /etc/systemd/system/overssh.service
        systemctl daemon-reload
        success "OverSSH systemd service removed"
    else
        log "OverSSH systemd service file not found"
    fi
}

restore_ssh_port() {
    log "Restoring SSH to port 22..."
    
    # Find the most recent backup
    BACKUP_FILE=$(ls -t /etc/ssh/sshd_config.backup.* 2>/dev/null | head -n1)
    
    if [ -n "$BACKUP_FILE" ] && [ -f "$BACKUP_FILE" ]; then
        log "Restoring SSH config from backup: $BACKUP_FILE"
        cp "$BACKUP_FILE" /etc/ssh/sshd_config
        
        # Test SSH configuration
        sshd -t
        if [ $? -eq 0 ]; then
            success "SSH configuration restored from backup"
        else
            error "Restored SSH configuration is invalid, manual intervention required"
            exit 1
        fi
    else
        warn "No SSH backup found, manually restoring SSH to port 22"
        
        # Manually restore to port 22
        if grep -q "^Port 2222" /etc/ssh/sshd_config; then
            sed -i 's/^Port 2222/Port 22/' /etc/ssh/sshd_config
        fi
        
        # Test configuration
        sshd -t
        if [ $? -eq 0 ]; then
            success "SSH manually restored to port 22"
        else
            error "SSH configuration is invalid, manual intervention required"
            exit 1
        fi
    fi
}

cleanup_firewall() {
    log "Cleaning up firewall rules..."
    
    if command -v ufw &> /dev/null; then
        # Remove OverSSH rules
        ufw delete allow 22/tcp comment 'OverSSH' 2>/dev/null || true
        
        # Remove Caddy rules
        ufw delete allow 80/tcp comment 'HTTP' 2>/dev/null || true
        ufw delete allow 443/tcp comment 'HTTPS' 2>/dev/null || true
        
        # Keep SSH rule but update comment if needed
        ufw delete allow 2222/tcp comment 'SSH' 2>/dev/null || true
        ufw allow 22/tcp comment 'SSH' 2>/dev/null || true
        
        success "Firewall rules updated"
    else
        log "ufw not found, skipping firewall cleanup"
    fi
}

cleanup_files() {
    log "Cleaning up deployment files..."
    
    # Remove production docker-compose file
    if [ -f docker-compose.prod.yml ]; then
        rm docker-compose.prod.yml
        log "Removed docker-compose.prod.yml"
    fi
    
    # Remove Caddyfile
    if [ -f Caddyfile ]; then
        rm Caddyfile
        log "Removed Caddyfile"
    fi
    
    success "File cleanup completed"
}

restart_ssh() {
    log "Restarting SSH service..."
    
    warn "Restarting SSH service - you will be disconnected!"
    warn "After restart, connect on port 22: ssh user@server"
    sleep 3
    
    systemctl restart ssh
    success "SSH service restarted on port 22"
}

show_final_status() {
    log "Uninstallation status:"
    echo
    echo "SSH Service (port 22):"
    systemctl status ssh --no-pager -l
    echo
    echo "Remaining Docker containers:"
    docker ps -a
    echo
    echo "Remaining Docker images:"
    docker images
    echo
    success "OverSSH uninstallation completed!"
    success "SSH is now back on port 22"
}

cleanup_ssh_backups() {
    log "Cleaning up old SSH backups (keeping the most recent)..."
    
    # Keep only the most recent backup
    BACKUPS=($(ls -t /etc/ssh/sshd_config.backup.* 2>/dev/null))
    if [ ${#BACKUPS[@]} -gt 1 ]; then
        for ((i=1; i<${#BACKUPS[@]}; i++)); do
            rm "${BACKUPS[i]}"
            log "Removed old backup: ${BACKUPS[i]}"
        done
    fi
    
    success "SSH backup cleanup completed"
}

main() {
    log "Starting OverSSH uninstallation..."
    
    check_root
    confirm_uninstall
    
    stop_overssh_service
    cleanup_docker
    remove_systemd_service
    restore_ssh_port
    cleanup_firewall
    cleanup_files
    cleanup_ssh_backups
    restart_ssh
    show_final_status
    
    success "OverSSH has been completely uninstalled!"
}

# Handle script interruption
trap 'error "Uninstallation interrupted"; exit 1' INT TERM

# Run main function
main "$@"