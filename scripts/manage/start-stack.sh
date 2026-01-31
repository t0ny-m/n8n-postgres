#!/usr/bin/env bash

set -e

# ============================================================================
# Stack Startup Script
# Starts selected services from n8n-stack
# ============================================================================

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Determine script location and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# If script is in scripts/manage/, go up two levels, otherwise stay in current dir
if [[ "$SCRIPT_DIR" == */scripts/manage ]]; then
    PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
else
    PROJECT_ROOT="$SCRIPT_DIR"
fi

# Paths
N8N_DIR="$PROJECT_ROOT/n8n"
SUPABASE_DIR="$PROJECT_ROOT/supabase"
NPM_DIR="$PROJECT_ROOT/proxy/npm"
CLOUDFLARED_DIR="$PROJECT_ROOT/proxy/cloudflared"
PORTAINER_DIR="$PROJECT_ROOT/portainer"
NETWORK_NAME="n8n-stack-network"

# Docker compose command (will be set by check_docker)
DOCKER_COMPOSE=""

# ============================================================================
# Helper Functions
# ============================================================================

print_header() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_info() {
    echo -e "${YELLOW}ℹ${NC} $1"
}

# ============================================================================
# Docker Check
# ============================================================================

check_docker() {
    print_header "Docker Check"
    
    # Check if docker command exists
    if ! command -v docker &>/dev/null; then
        print_error "Docker is not installed or not in PATH"
        echo ""
        
        # Detect OS and provide specific instructions
        case "$(uname -s)" in
            Linux*)
                echo "Install Docker on Linux:"
                echo "  curl -fsSL https://get.docker.com | sh"
                echo "  sudo usermod -aG docker \$USER"
                echo ""
                echo "Then logout/login or run: newgrp docker"
                ;;
            Darwin*)
                echo "Install Docker Desktop for macOS:"
                echo "  https://docs.docker.com/desktop/install/mac-install/"
                echo ""
                if command -v brew &>/dev/null; then
                    echo "Or via Homebrew:"
                    echo "  brew install --cask docker"
                else
                    echo "Note: Homebrew is not installed. Install Docker Desktop manually."
                fi
                ;;
            MINGW*|MSYS*|CYGWIN*)
                echo "Install Docker Desktop for Windows:"
                echo "  https://docs.docker.com/desktop/install/windows-install/"
                echo ""
                echo "Make sure WSL2 backend is enabled"
                ;;
            *)
                echo "Install Docker for your system:"
                echo "  https://docs.docker.com/get-docker/"
                ;;
        esac
        
        echo ""
        exit 1
    fi
    
    # Check if Docker daemon is running
    if ! docker info &>/dev/null; then
        print_error "Docker is installed but not running"
        echo ""
        
        case "$(uname -s)" in
            Linux*)
                echo "Start Docker service:"
                echo "  sudo systemctl start docker"
                echo "  sudo systemctl enable docker"
                ;;
            Darwin*|MINGW*|MSYS*|CYGWIN*)
                echo "Start Docker Desktop application"
                echo ""
                echo "On macOS/Windows, Docker Desktop must be running"
                echo "Look for the Docker icon in your system tray/menu bar"
                ;;
        esac
        
        echo ""
        exit 1
    fi
    
    # Check docker compose
    if docker compose version &>/dev/null; then
        DOCKER_COMPOSE="docker compose"
    elif docker-compose version &>/dev/null; then
        print_info "Using legacy docker-compose command"
        DOCKER_COMPOSE="docker-compose"
    else
        print_error "Docker Compose is not available"
        echo ""
        echo "Docker Compose should be included with Docker Desktop"
        echo "If using Linux, install docker-compose-plugin:"
        echo "  sudo apt-get install docker-compose-plugin"
        echo ""
        exit 1
    fi
    
    # Success
    DOCKER_VERSION=$(docker --version | cut -d' ' -f3 | cut -d',' -f1)
    COMPOSE_VERSION=$($DOCKER_COMPOSE version --short 2>/dev/null || echo "unknown")
    
    print_success "Docker ${DOCKER_VERSION} is running"
    print_success "Docker Compose ${COMPOSE_VERSION} is available"
    echo ""
}

# ============================================================================
# Port Checking & Firewall Management
# ============================================================================

# Check if a port is in use
is_port_in_use() {
    local port=$1
    if command -v lsof &>/dev/null; then
        lsof -Pi :$port -sTCP:LISTEN -t >/dev/null 2>&1
    elif command -v ss &>/dev/null; then
        ss -tuln | grep -q ":$port "
    elif command -v netstat &>/dev/null; then
        netstat -tuln | grep -q ":$port "
    else
        return 1  # Can't check, assume not in use
    fi
}

# Check if a port is open in firewall
is_port_open_in_firewall() {
    local port=$1
    
    # Only check on Linux
    [[ "$(uname -s)" != "Linux" ]] && return 0
    
    if command -v ufw &>/dev/null && sudo ufw status 2>/dev/null | grep -q "Status: active"; then
        sudo ufw status | grep -qE "^$port(/tcp)?.*ALLOW"
    elif command -v firewall-cmd &>/dev/null; then
        sudo firewall-cmd --query-port=$port/tcp 2>/dev/null
    else
        return 0  # No firewall detected, assume open
    fi
}

# Open port in firewall
open_port_in_firewall() {
    local port=$1
    
    if command -v ufw &>/dev/null && sudo ufw status 2>/dev/null | grep -q "Status: active"; then
        sudo ufw allow $port/tcp
    elif command -v firewall-cmd &>/dev/null; then
        sudo firewall-cmd --permanent --add-port=$port/tcp
        sudo firewall-cmd --reload
    fi
}

# Show instructions for opening ports
show_port_instructions() {
    local ports=("$@")
    local ports_str="${ports[*]}"
    
    echo ""
    print_info "Please open the following ports manually:"
    echo "  Ports: ${ports_str// /, }"
    echo ""
    echo "  UFW (Ubuntu/Debian):"
    for port in "${ports[@]}"; do
        echo "    sudo ufw allow $port/tcp"
    done
    echo ""
    echo "  Firewalld (CentOS/RHEL):"
    for port in "${ports[@]}"; do
        echo "    sudo firewall-cmd --permanent --add-port=$port/tcp"
    done
    echo "    sudo firewall-cmd --reload"
    echo ""
    echo -e "  ${YELLOW}⚠ Don't forget to open ports in your cloud provider's firewall/security group!${NC}"
    echo ""
}

# Main port check function
check_and_open_ports() {
    local ports=("$@")
    local in_use_ports=()
    local closed_ports=()
    
    print_header "Port Check"
    
    # Check for occupied ports
    for port in "${ports[@]}"; do
        if is_port_in_use "$port"; then
            in_use_ports+=($port)
            print_error "Port $port is already in use"
            if command -v lsof &>/dev/null; then
                lsof -i :$port | grep LISTEN | head -3
            fi
        else
            print_success "Port $port is available"
        fi
    done
    
    # If ports are in use, warn user
    if [ ${#in_use_ports[@]} -gt 0 ]; then
        echo ""
        print_error "Some ports are already in use: ${in_use_ports[*]}"
        echo "Services using these ports may fail to start."
        read -rp "Continue anyway? [y/N]: " response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            print_error "Operation cancelled by user"
            exit 0
        fi
    fi
    
    # Only check firewall on Linux
    if [[ "$(uname -s)" != "Linux" ]]; then
        print_info "Skipping firewall check (not on Linux)"
        return 0
    fi
    
    # Check firewall
    print_header "Firewall Check"
    
    # Detect firewall type
    local firewall_type=""
    if command -v ufw &>/dev/null && sudo ufw status 2>/dev/null | grep -q "Status: active"; then
        firewall_type="ufw"
        print_info "Detected active firewall: UFW"
    elif command -v firewall-cmd &>/dev/null && sudo firewall-cmd --state 2>/dev/null | grep -q "running"; then
        firewall_type="firewalld"
        print_info "Detected active firewall: firewalld"
    else
        print_info "No active firewall detected (ufw/firewalld)"
        echo ""
        echo -e "${YELLOW}⚠ Note: If you're on a VPS, check your cloud provider's firewall/security group!${NC}"
        echo "  Required ports: ${ports[*]}"
        echo ""
        return 0
    fi
    
    # Check which ports need to be opened
    for port in "${ports[@]}"; do
        if ! is_port_open_in_firewall "$port"; then
            closed_ports+=($port)
            print_error "Port $port is closed in firewall"
        else
            print_success "Port $port is open in firewall"
        fi
    done
    
    # If no ports need to be opened, we're done
    if [ ${#closed_ports[@]} -eq 0 ]; then
        print_success "All required ports are open"
        return 0
    fi
    
    # Ask user if they want to open ports
    echo ""
    print_info "The following ports need to be opened: ${closed_ports[*]}"
    read -rp "Open these ports automatically? (requires sudo) [Y/n]: " response
    
    if [[ ! "$response" =~ ^[Nn]$ ]]; then
        # Try to open ports
        local failed_ports=()
        for port in "${closed_ports[@]}"; do
            echo -n "Opening port $port... "
            if open_port_in_firewall "$port" 2>/dev/null; then
                echo -e "${GREEN}OK${NC}"
            else
                echo -e "${RED}FAILED${NC}"
                failed_ports+=($port)
            fi
        done
        
        if [ ${#failed_ports[@]} -gt 0 ]; then
            show_port_instructions "${failed_ports[@]}"
        else
            print_success "All ports opened successfully"
            echo ""
            echo -e "${YELLOW}⚠ Remember: Also open these ports in your cloud provider's firewall!${NC}"
        fi
    else
        show_port_instructions "${closed_ports[@]}"
    fi
    
    echo ""
}

# Determine which ports to check based on selected services
get_required_ports() {
    local ports=()
    
    # Load port values from supabase .env if it exists
    local KONG_HTTP_PORT=8000
    local KONG_HTTPS_PORT=8443
    local POSTGRES_PORT=5432
    local POOLER_PROXY_PORT_TRANSACTION=6543
    
    if [ -f "$SUPABASE_DIR/.env" ]; then
        source "$SUPABASE_DIR/.env" 2>/dev/null || true
    fi
    
    if $START_NPM && ! $START_CLOUDFLARED; then
        # NPM selected - only need 80, 81, 443
        ports=(80 81 443)
    elif $START_CLOUDFLARED; then
        # Cloudflared selected - no ports needed
        ports=()
    elif $START_SUPABASE && ! $START_NPM; then
        # Full Supabase without NPM - need all Supabase ports
        ports=($POSTGRES_PORT $POOLER_PROXY_PORT_TRANSACTION 4000 $KONG_HTTP_PORT $KONG_HTTPS_PORT)
        if $START_N8N; then
            ports+=(5678)
        fi
    elif $START_N8N && ! $START_SUPABASE && ! $START_NPM; then
        # n8n only (minimal Supabase) - need n8n + db ports
        ports=(5678 $POSTGRES_PORT $POOLER_PROXY_PORT_TRANSACTION 4000)
    fi
    
    # Remove duplicates
    printf '%s\n' "${ports[@]}" | sort -u | tr '\n' ' '
}

# Create network if it doesn't exist
create_network() {
    print_header "Network Setup"
    
    if docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
        print_info "Network '$NETWORK_NAME' already exists"
    else
        print_info "Creating network '$NETWORK_NAME'..."
        docker network create "$NETWORK_NAME"
        print_success "Network created successfully"
    fi
}

# Wait for container to be healthy
wait_for_healthy() {
    local container=$1
    local timeout=${2:-60}
    local elapsed=0
    
    echo -n "Waiting for $container to be healthy..."
    
    while [ $elapsed -lt $timeout ]; do
        status=$(docker inspect "$container" --format='{{.State.Health.Status}}' 2>/dev/null || echo "not_found")
        
        if [ "$status" = "healthy" ]; then
            echo ""
            print_success "$container is healthy"
            return 0
        fi
        
        echo -n "."
        sleep 2
        elapsed=$((elapsed + 2))
    done
    
    echo ""
    print_error "$container did not become healthy within ${timeout}s"
    return 1
}

# Check if directory exists
check_dir() {
    if [ ! -d "$1" ]; then
        print_error "Directory not found: $1"
        return 1
    fi
    return 0
}

# Start service with recreation
start_service() {
    local service_name=$1
    local service_dir=$2
    local description=$3
    local wait_healthy=$4  # Optional: container name to wait for
    
    print_header "Starting: $description"
    
    if ! check_dir "$service_dir"; then
        print_error "Skipping $service_name (directory not found)"
        return 1
    fi
    
    print_info "Working directory: $service_dir"
    cd "$service_dir"
    
    # Recreate containers
    print_info "Stopping existing containers..."
    $DOCKER_COMPOSE down 2>/dev/null || true
    
    print_info "Starting containers..."
    $DOCKER_COMPOSE up -d
    
    # Wait for health check if specified
    if [ -n "$wait_healthy" ]; then
        wait_for_healthy "$wait_healthy" 60
    fi
    
    print_success "$description started successfully"
    echo ""
}

# ============================================================================
# Service Selection - Interactive Menu (whiptail/dialog)
# ============================================================================

select_services_interactive() {
    local cmd=""
    
    # Detect available dialog tool
    if command -v whiptail &>/dev/null; then
        cmd="whiptail"
    elif command -v dialog &>/dev/null; then
        cmd="dialog"
    else
        return 1  # Fall back to simple mode
    fi
    
    # Build checklist
    local options=(
        "n8n" "n8n workflow automation" OFF
        "supabase" "Supabase (full stack)" OFF
        "npm" "Nginx Proxy Manager" OFF
        "cloudflared" "Cloudflared Tunnel" OFF
        "portainer" "Portainer" OFF
    )
    
    local selected
    if [ "$cmd" = "whiptail" ]; then
        selected=$(whiptail --title "Stack Startup" \
            --checklist "Select services to start (Space to select, Enter to confirm):" \
            20 70 10 \
            "${options[@]}" \
            3>&1 1>&2 2>&3)
    else
        selected=$(dialog --stdout --title "Stack Startup" \
            --checklist "Select services to start (Space to select, Enter to confirm):" \
            20 70 10 \
            "${options[@]}")
    fi
    
    # Check if user cancelled
    if [ $? -ne 0 ]; then
        echo ""
        print_error "Operation cancelled by user"
        exit 0
    fi
    
    # Parse selected services
    START_N8N=false
    START_SUPABASE=false
    START_NPM=false
    START_CLOUDFLARED=false
    START_PORTAINER=false
    
    for service in $selected; do
        case $service in
            \"n8n\"|n8n)
                START_N8N=true
                ;;
            \"supabase\"|supabase)
                START_SUPABASE=true
                ;;
            \"npm\"|npm)
                START_NPM=true
                ;;
            \"cloudflared\"|cloudflared)
                START_CLOUDFLARED=true
                ;;
            \"portainer\"|portainer)
                START_PORTAINER=true
                ;;
        esac
    done
}

# ============================================================================
# Service Selection - Simple Mode (yes/no questions)
# ============================================================================

select_services_simple() {
    print_header "Service Selection"
    echo "Answer yes (y) or no (n) for each service:"
    echo ""
    
    START_N8N=false
    read -rp "Start n8n? [y/N]: " response
    if [[ "$response" =~ ^[Yy]$ ]]; then
        START_N8N=true
    fi
    
    START_SUPABASE=false
    read -rp "Start Supabase (full stack)? [y/N]: " response
    if [[ "$response" =~ ^[Yy]$ ]]; then
        START_SUPABASE=true
    fi
    
    START_NPM=false
    read -rp "Start Nginx Proxy Manager? [y/N]: " response
    if [[ "$response" =~ ^[Yy]$ ]]; then
        START_NPM=true
    fi
    
    START_CLOUDFLARED=false
    read -rp "Start Cloudflared Tunnel? [y/N]: " response
    if [[ "$response" =~ ^[Yy]$ ]]; then
        START_CLOUDFLARED=true
    fi
    
    START_PORTAINER=false
    read -rp "Start Portainer? [y/N]: " response
    if [[ "$response" =~ ^[Yy]$ ]]; then
        START_PORTAINER=true
    fi
}


# ============================================================================
# Main Logic
# ============================================================================

main() {
    print_header "n8n Stack Startup Script"
    echo "Project root: $PROJECT_ROOT"
    
    # Step 0: Check Docker
    check_docker
    
    # Step 1: Create network
    create_network
    
    # Step 2: Select services
    if ! select_services_interactive; then
        # Fallback to simple mode if whiptail/dialog not available
        print_info "Interactive menu not available, using simple mode"
        select_services_simple
    fi
    
    # Step 3: Summary
    print_header "Selected Services"
    echo "The following services will be started:"
    echo ""
    $START_N8N && echo "  • n8n (+ minimal Supabase: db, vector)"
    $START_SUPABASE && echo "  • Supabase (full stack)"
    $START_NPM && echo "  • Nginx Proxy Manager"
    $START_CLOUDFLARED && echo "  • Cloudflared Tunnel"
    $START_PORTAINER && echo "  • Portainer"
    echo ""
    
    # Check if nothing selected
    if ! $START_N8N && ! $START_SUPABASE && ! $START_NPM && ! $START_CLOUDFLARED && ! $START_PORTAINER; then
        print_error "No services selected. Exiting."
        exit 0
    fi
    
    read -rp "Continue? [Y/n]: " response
    if [[ "$response" =~ ^[Nn]$ ]]; then
        print_error "Operation cancelled by user"
        exit 0
    fi
    
    # Step 4: Check ports and firewall
    REQUIRED_PORTS=$(get_required_ports)
    if [ -n "$REQUIRED_PORTS" ]; then
        # Convert space-separated string to array
        read -ra PORT_ARRAY <<< "$REQUIRED_PORTS"
        check_and_open_ports "${PORT_ARRAY[@]}"
    else
        print_info "Using Cloudflared Tunnel - no port check needed"
    fi
    
    # Step 5: Start services in correct order
    
    # 4.1: Supabase (if needed)
    SUPABASE_STARTED=false
    
    if $START_SUPABASE; then
        # Full Supabase stack
        start_service "supabase" "$SUPABASE_DIR" "Supabase (full stack)"
        wait_for_healthy "supabase-db" 60
        SUPABASE_STARTED=true
    elif $START_N8N; then
        # Minimal Supabase for n8n (only db dependencies)
        print_header "Starting: Supabase (minimal for n8n)"
        
        if check_dir "$SUPABASE_DIR"; then
            cd "$SUPABASE_DIR"
            
            print_info "Stopping existing Supabase containers..."
            $DOCKER_COMPOSE down 2>/dev/null || true
            
            print_info "Starting minimal Supabase (vector, db)..."
            $DOCKER_COMPOSE up -d vector db
            
            wait_for_healthy "supabase-db" 60
            
            print_success "Minimal Supabase started successfully"
            echo ""
            SUPABASE_STARTED=true
        fi
    fi
    
    # 4.2: n8n (depends on Supabase db)
    if $START_N8N; then
        if ! $SUPABASE_STARTED; then
            print_error "Cannot start n8n: Supabase database not started"
        else
            start_service "n8n" "$N8N_DIR" "n8n"
        fi
    fi
    
    # 4.3: Independent services (no waiting needed)
    if $START_NPM; then
        start_service "npm" "$NPM_DIR" "Nginx Proxy Manager"
    fi

    if $START_CLOUDFLARED; then
        start_service "cloudflared" "$CLOUDFLARED_DIR" "Cloudflared Tunnel"
    fi

    if $START_PORTAINER; then
        start_service "portainer" "$PORTAINER_DIR" "Portainer"
    fi

    # Final summary
    print_header "Startup Complete"
    echo "Running containers:"
    echo ""
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep -E "n8n|supabase|npm|cloudflared|portainer" || print_info "No containers found"
    echo ""
    print_success "All selected services started successfully!"
    echo ""
}

# Run main function
main