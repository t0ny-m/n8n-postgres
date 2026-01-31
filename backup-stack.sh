#!/usr/bin/env bash

set -e

# ============================================================================
# Stack Backup Script
# Backs up selected services from n8n-stack to a .tar.gz archive
# ============================================================================

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Determine script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Find project root by looking for start-stack.sh
current_dir="$SCRIPT_DIR"
PROJECT_ROOT=""

while [[ "$current_dir" != "/" ]]; do
    if [[ -f "$current_dir/start-stack.sh" ]]; then
        PROJECT_ROOT="$current_dir"
        break
    fi
    current_dir="$(dirname "$current_dir")"
done

if [[ -z "$PROJECT_ROOT" ]]; then
    echo -e "${RED}Error: Could not find project root (start-stack.sh not found).${NC}"
    exit 1
fi

# Paths
BACKUPS_DIR="$PROJECT_ROOT/backups"
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M")

# Service Paths
N8N_DIR="$PROJECT_ROOT/n8n"
SUPABASE_DIR="$PROJECT_ROOT/supabase"
NPM_DIR="$PROJECT_ROOT/proxy/npm"
CLOUDFLARED_DIR="$PROJECT_ROOT/proxy/cloudflared"
PORTAINER_DIR="$PROJECT_ROOT/portainer"

# Arrays to keep track of created backups for final archiving (paths relative to BACKUPS_DIR)
CREATED_BACKUPS=()

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

check_dependencies() {
    if ! command -v docker &>/dev/null; then
        print_error "Docker is not installed or not in PATH"
        exit 1
    fi
    
    if ! command -v tar &>/dev/null; then
        print_error "tar command not found"
        exit 1
    fi
}

# ============================================================================
# Service Selection
# ============================================================================

select_services_interactive() {
    local cmd=""
    
    if command -v whiptail &>/dev/null; then
        cmd="whiptail"
    elif command -v dialog &>/dev/null; then
        cmd="dialog"
    else
        return 1
    fi
    
    local options=(
        "n8n" "n8n workflow automation (env, files, volume)" OFF
        "supabase" "Supabase (env, db data, storage)" OFF
        "npm" "Nginx Proxy Manager (data, certs)" OFF
        "cloudflared" "Cloudflared Tunnel (env)" OFF
        "portainer" "Portainer (volume)" OFF
    )
    
    local selected
    if [ "$cmd" = "whiptail" ]; then
        selected=$(whiptail --title "Stack Backup" \
            --checklist "Select services to backup (Space to select, Enter to confirm):" \
            20 70 10 \
            "${options[@]}" \
            3>&1 1>&2 2>&3)
    else
        selected=$(dialog --stdout --title "Stack Backup" \
            --checklist "Select services to backup (Space to select, Enter to confirm):" \
            20 70 10 \
            "${options[@]}")
    fi
    
    if [ $? -ne 0 ]; then
        echo ""
        print_error "Operation cancelled by user"
        exit 0
    fi
    
    BACKUP_N8N=false
    BACKUP_SUPABASE=false
    BACKUP_NPM=false
    BACKUP_CLOUDFLARED=false
    BACKUP_PORTAINER=false
    
    for service in $selected; do
        case $service in
            \"n8n\"|n8n) BACKUP_N8N=true ;;
            \"supabase\"|supabase) BACKUP_SUPABASE=true ;;
            \"npm\"|npm) BACKUP_NPM=true ;;
            \"cloudflared\"|cloudflared) BACKUP_CLOUDFLARED=true ;;
            \"portainer\"|portainer) BACKUP_PORTAINER=true ;;
        esac
    done
}

select_services_simple() {
    print_header "Service Selection"
    echo "Answer yes (y) or no (n) for each service:"
    echo ""
    
    BACKUP_N8N=false
    read -rp "Backup n8n? [y/N]: " response
    if [[ "$response" =~ ^[Yy]$ ]]; then BACKUP_N8N=true; fi
    
    BACKUP_SUPABASE=false
    read -rp "Backup Supabase? [y/N]: " response
    if [[ "$response" =~ ^[Yy]$ ]]; then BACKUP_SUPABASE=true; fi
    
    BACKUP_NPM=false
    read -rp "Backup Nginx Proxy Manager? [y/N]: " response
    if [[ "$response" =~ ^[Yy]$ ]]; then BACKUP_NPM=true; fi
    
    BACKUP_CLOUDFLARED=false
    read -rp "Backup Cloudflared Tunnel? [y/N]: " response
    if [[ "$response" =~ ^[Yy]$ ]]; then BACKUP_CLOUDFLARED=true; fi
    
    BACKUP_PORTAINER=false
    read -rp "Backup Portainer? [y/N]: " response
    if [[ "$response" =~ ^[Yy]$ ]]; then BACKUP_PORTAINER=true; fi
}

# ============================================================================
# Backup Logic
# ============================================================================

# Backup named volume using a temporary container
backup_named_volume() {
    local volume_name=$1
    local dest_file=$2
    
    print_info "Backing up volume: $volume_name"
    
    # Check if volume exists
    if ! docker volume inspect "$volume_name" &>/dev/null; then
        print_error "Volume $volume_name does not exist, jumping..."
        echo "Volume $volume_name skipped" > "$dest_file.skipped"
        return 0
    fi
    
    # Run busybox to tar the volume content to stdout, then save to file
    docker run --rm \
        -v "$volume_name":/volume \
        -v "$(dirname "$dest_file")":/backup \
        alpine:latest \
        tar -czf "/backup/$(basename "$dest_file")" -C /volume .
        
    print_success "Volume backed up to $dest_file"
}

backup_n8n() {
    local folder_name="n8n_backup_${TIMESTAMP}"
    local service_path="n8n/$folder_name"
    local full_path="$BACKUPS_DIR/$service_path"
    
    print_header "Backing up n8n"
    mkdir -p "$full_path"
    
    # Files
    if [ -d "$N8N_DIR" ]; then
        print_info "Copying configuration files..."
        cp -r "$N8N_DIR/.env" "$full_path/.env" 2>/dev/null || true
        
        if [ -d "$N8N_DIR/files" ]; then
             mkdir -p "$full_path/files"
             cp -r "$N8N_DIR/files/"* "$full_path/files/" 2>/dev/null || true
        fi
        
    # Volume n8n_data (files)
        backup_named_volume "n8n_n8n_data" "$full_path/n8n_data.tar.gz"
        
        # Volume db_storage (postgres data)
        backup_named_volume "n8n_db_storage" "$full_path/n8n_db_storage.tar.gz"
        
        CREATED_BACKUPS+=("$service_path")
        print_success "n8n backup created at: backups/$service_path"
    else
        print_error "n8n directory not found at $N8N_DIR"
    fi
}

backup_supabase() {
    local folder_name="supabase_backup_${TIMESTAMP}"
    local service_path="supabase/$folder_name"
    local full_path="$BACKUPS_DIR/$service_path"

    print_header "Backing up Supabase"
    mkdir -p "$full_path"
    
    if [ -d "$SUPABASE_DIR" ]; then
        print_info "Copying configuration files..."
        cp "$SUPABASE_DIR/.env" "$full_path/.env" 2>/dev/null || true
        cp "$SUPABASE_DIR/docker-compose.yml" "$full_path/docker-compose.yml" 2>/dev/null || true
        
        # Volumes (bind mounts)
        if [ -d "$SUPABASE_DIR/volumes" ]; then
            print_info "Copying data volumes (this make take a while)..."
            # We copy the whole volumes directory which contains db, storage, etc.
            # Using rsync if available for better handling, else cp
            if command -v rsync &>/dev/null; then
                rsync -a --exclude 'postgres_data' "$SUPABASE_DIR/volumes" "$full_path/"
            else
                cp -R "$SUPABASE_DIR/volumes" "$full_path/"
            fi
        fi
        
        CREATED_BACKUPS+=("$service_path")
        print_success "Supabase backup created at: backups/$service_path"
    else
        print_error "Supabase directory not found at $SUPABASE_DIR"
    fi
}

backup_npm() {
    local folder_name="npm_backup_${TIMESTAMP}"
    local service_path="npm/$folder_name"
    local full_path="$BACKUPS_DIR/$service_path"

    print_header "Backing up Nginx Proxy Manager"
    mkdir -p "$full_path"
    
    if [ -d "$NPM_DIR" ]; then
        print_info "Copying data and certificates..."
        # NPM uses bind mounts for data and letsencrypt
        if [ -d "$NPM_DIR/data" ]; then
             cp -R "$NPM_DIR/data" "$full_path/"
        fi
        if [ -d "$NPM_DIR/letsencrypt" ]; then
             cp -R "$NPM_DIR/letsencrypt" "$full_path/"
        fi
        
        CREATED_BACKUPS+=("$service_path")
        print_success "NPM backup created at: backups/$service_path"
    else
        print_error "NPM directory not found at $NPM_DIR"
    fi
}

backup_cloudflared() {
    local folder_name="cloudflared_backup_${TIMESTAMP}"
    local service_path="cloudflared/$folder_name"
    local full_path="$BACKUPS_DIR/$service_path"

    print_header "Backing up Cloudflared"
    mkdir -p "$full_path"
    
    if [ -d "$CLOUDFLARED_DIR" ]; then
        print_info "Copying configuration..."
        cp "$CLOUDFLARED_DIR/.env" "$full_path/.env" 2>/dev/null || true
        
        CREATED_BACKUPS+=("$service_path")
        print_success "Cloudflared backup created at: backups/$service_path"
    else
        print_error "Cloudflared directory not found at $CLOUDFLARED_DIR"
    fi
}

backup_portainer() {
    local folder_name="portainer_backup_${TIMESTAMP}"
    local service_path="portainer/$folder_name"
    local full_path="$BACKUPS_DIR/$service_path"

    print_header "Backing up Portainer"
    mkdir -p "$full_path"
    
    # Volume portainer_data
    backup_named_volume "portainer_data" "$full_path/portainer_data.tar.gz"
    
    CREATED_BACKUPS+=("$service_path")
    print_success "Portainer backup created at: backups/$service_path"
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

# ============================================================================
# Main
# ============================================================================


# ============================================================================
# Main
# ============================================================================

main() {
    print_header "n8n Stack Backup Script"
    check_dependencies
    
    # Service Selection
    if ! select_services_interactive; then
        print_info "Interactive menu not available, using simple mode"
        select_services_simple
    fi
    
    # Check if anything selected
    if ! $BACKUP_N8N && ! $BACKUP_SUPABASE && ! $BACKUP_NPM && ! $BACKUP_CLOUDFLARED && ! $BACKUP_PORTAINER; then
        print_error "No services selected for backup. Exiting."
        exit 0
    fi
    
    # Comfirmation and Stop Warning
    echo ""
    print_info "Selected services will be backed up."
    echo -e "${YELLOW}IMPORTANT: For consistent backups (especially databases), it is recommended to stop services.${NC}"
    read -rp "Do you want to stop the selected services before backup? [y/N]: " stop_response
    
    # Make sure backups dir exists
    mkdir -p "$BACKUPS_DIR"
    
    # Capture State & Stop Services
    SUPABASE_RUNNING=""
    N8N_RUNNING=""
    NPM_RUNNING=""
    CLOUDFLARED_RUNNING=""
    PORTAINER_RUNNING=""
    
    if [[ "$stop_response" =~ ^[Yy]$ ]]; then
        print_header "Stopping Services"
        
        # 1. n8n
        if $BACKUP_N8N; then
            if [ -d "$N8N_DIR" ]; then
                print_info "Checking n8n state..."
                # Check if n8n is running
                if docker compose -f "$N8N_DIR/docker-compose.yml" ps --services --filter "status=running" | grep -q "n8n"; then
                    N8N_RUNNING="true"
                    
                    # LOGICAL BACKUP (pg_dump) needs running DB
                    # Check for n8n-db container
                    if docker ps | grep -q "n8n-db"; then
                        print_info "Creating logical backup (SQL dump) of n8n database..."
                        
                        # Define path matching backup_n8n function
                        local folder_name="n8n_backup_${TIMESTAMP}"
                        local dump_dir="$BACKUPS_DIR/n8n/$folder_name"
                        mkdir -p "$dump_dir"
                        
                        local search_path_dump="$dump_dir/n8n_db_dump.sql"
                        
                        # Load env to get credentials check
                        source "$N8N_DIR/.env" 2>/dev/null || true
                        local db_user=${POSTGRES_USER:-postgres_user}
                        local db_name=${POSTGRES_DB:-n8n}
                        
                        if docker exec n8n-db pg_dump -U "$db_user" -d "$db_name" > "$search_path_dump" 2>/dev/null; then
                            print_success "Logical backup created: $search_path_dump"
                        else
                            print_error "Failed to create logical backup (is n8n-db healthy?)"
                        fi
                    else
                        print_info "n8n-db container not running, skipping logical backup."
                    fi

                    print_info "Stopping n8n..."
                    cd "$N8N_DIR" && docker compose down 2>/dev/null || true
                fi
            fi
        fi
        
        # 2. Supabase
        # We handle Supabase if it's selected OR if n8n is selected (dependency)
        if $BACKUP_SUPABASE || $BACKUP_N8N; then
            if [ -d "$SUPABASE_DIR" ]; then
                print_info "Checking Supabase state..."
                # Get list of running services
                cd "$SUPABASE_DIR"
                SUPABASE_RUNNING=$(docker compose ps --services --filter "status=running")
                
                if [ -n "$SUPABASE_RUNNING" ]; then
                    if $BACKUP_SUPABASE; then
                        print_info "Stopping Supabase (Backup selected)..."
                    else
                        print_info "Stopping Supabase (Dependency for n8n)..."
                    fi
                    docker compose down 2>/dev/null || true
                fi
            fi
        fi
        
        # 3. NPM
        if $BACKUP_NPM; then
            if [ -d "$NPM_DIR" ]; then
                cd "$NPM_DIR"
                if docker compose ps --services --filter "status=running" | grep -q "npm"; then
                    NPM_RUNNING="true"
                    print_info "Stopping NPM..."
                    docker compose down 2>/dev/null || true
                fi
            fi
        fi
        
        # 4. Cloudflared
        if $BACKUP_CLOUDFLARED; then
             if [ -d "$CLOUDFLARED_DIR" ]; then
                cd "$CLOUDFLARED_DIR"
                if docker compose ps --services --filter "status=running" | grep -q "cloudflared"; then
                    CLOUDFLARED_RUNNING="true"
                    print_info "Stopping Cloudflared..."
                    docker compose down 2>/dev/null || true
                fi
            fi
        fi
        
        # 5. Portainer
        if $BACKUP_PORTAINER; then
             if [ -d "$PORTAINER_DIR" ]; then
                 print_info "Checking Portainer state..."
                 cd "$PORTAINER_DIR"
                 if docker compose ps --services --filter "status=running" | grep -q "portainer"; then
                     PORTAINER_RUNNING="true"
                     print_info "Stopping Portainer..."
                     docker compose down 2>/dev/null || true
                 fi
             fi
        fi

        
        echo ""
    fi
    
    # Perform Backups
    $BACKUP_N8N && backup_n8n
    $BACKUP_SUPABASE && backup_supabase
    $BACKUP_NPM && backup_npm
    $BACKUP_CLOUDFLARED && backup_cloudflared
    $BACKUP_PORTAINER && backup_portainer
    
    # Restart Services
    if [[ "$stop_response" =~ ^[Yy]$ ]]; then
        print_header "Restarting Services"
        
        # 1. Supabase (Priority)
        if [ -n "$SUPABASE_RUNNING" ]; then
            print_info "Restarting Supabase services: $(echo "$SUPABASE_RUNNING" | tr '\n' ' ')"
            cd "$SUPABASE_DIR"
            # Quote variable to handle newlines if any, though docker compose usually takes args
            # We convert newlines to spaces for the command
            SERVICES_TO_START=$(echo "$SUPABASE_RUNNING" | tr '\n' ' ')
            docker compose up -d $SERVICES_TO_START
            
            # Wait for DB if it was running
            if echo "$SUPABASE_RUNNING" | grep -q "db"; then
                wait_for_healthy "supabase-db" 60
            fi
        fi
        
        # 2. n8n
        if [ "$N8N_RUNNING" = "true" ]; then
            print_info "Restarting n8n..."
            cd "$N8N_DIR" && docker compose up -d
        fi
        
        # 3. Others
        if [ "$NPM_RUNNING" = "true" ]; then
             print_info "Starting NPM..."
             cd "$NPM_DIR" && docker compose up -d
        fi
        
        if [ "$CLOUDFLARED_RUNNING" = "true" ]; then
             print_info "Starting Cloudflared..."
             cd "$CLOUDFLARED_DIR" && docker compose up -d
        fi
        
        if [ "$PORTAINER_RUNNING" = "true" ]; then
             print_info "Starting Portainer..."
             cd "$PORTAINER_DIR" && docker compose up -d
        fi
    fi
    
    print_header "Backup Complete"
    
    if [ ${#CREATED_BACKUPS[@]} -gt 0 ]; then
         print_info "Created backups:"
         for backup in "${CREATED_BACKUPS[@]}"; do
             echo " - backups/$backup"
         done
         echo ""
         
         # Optional Archiving
         read -rp "Do you want to create a single archive (.tar.gz) containing these backups? [y/N]: " archive_response
         if [[ "$archive_response" =~ ^[Yy]$ ]]; then
            ARCHIVE_NAME="n8n_stack_backup_${TIMESTAMP}.tar.gz"
            ARCHIVE_FILE="${BACKUPS_DIR}/${ARCHIVE_NAME}"
            
            print_info "Creating archive: $ARCHIVE_NAME"
            cd "$BACKUPS_DIR"
            
            # Tar only the folders we created
            tar -czf "$ARCHIVE_NAME" "${CREATED_BACKUPS[@]}"
            
            if [ $? -eq 0 ]; then
                print_success "Archive created: backups/$ARCHIVE_NAME"
                echo "Size: $(du -h "$ARCHIVE_NAME" | cut -f1)"
            else
                print_error "Failed to create archive"
            fi
         fi
    else
        print_info "No backups were created."
    fi
    
    echo ""
}

main