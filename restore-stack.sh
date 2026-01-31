#!/usr/bin/env bash

set -e

# ============================================================================
# Stack Restore Script
# Restores selected services from local backups
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
TEMP_RESTORE_DIR="$PROJECT_ROOT/temp_restore_$(date +%s)"

# Service Paths
N8N_DIR="$PROJECT_ROOT/n8n"
SUPABASE_DIR="$PROJECT_ROOT/supabase"
NPM_DIR="$PROJECT_ROOT/proxy/npm"
CLOUDFLARED_DIR="$PROJECT_ROOT/proxy/cloudflared"
PORTAINER_DIR="$PROJECT_ROOT/portainer"

# State variables
RESTORE_N8N=false
RESTORE_SUPABASE=false
RESTORE_NPM=false
RESTORE_CLOUDFLARED=false
RESTORE_PORTAINER=false

# Backup sources (populated during scan)
SOURCE_TYPE="" # "archive" or "folders"
SELECTED_ARCHIVE=""
LATEST_N8N_BACKUP=""
LATEST_SUPABASE_BACKUP=""
LATEST_NPM_BACKUP=""
LATEST_CLOUDFLARED_BACKUP=""
LATEST_PORTAINER_BACKUP=""

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

print_warning() {
    echo -e "${YELLOW}⚠ WARNING: $1${NC}"
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
# Discovery Logic
# ============================================================================

find_latest_backup_in_dir() {
    local service_dir="$BACKUPS_DIR/$1"
    if [ ! -d "$service_dir" ]; then
        echo ""
        return
    fi
    
    # ls -dt sorts by time (newest first)
    # filter for directories that look like backups, e.g., *_backup_*
    local latest=$(ls -dt "$service_dir"/*_backup_* 2>/dev/null | head -n 1)
    echo "$latest"
}

find_backups() {
    print_info "Scanning for backups..."
    
    # 1. Check for global archives
    # We look for files matching n8n_stack_backup_*.tar.gz
    LATEST_ARCHIVE=$(ls -t "$BACKUPS_DIR"/n8n_stack_backup_*.tar.gz 2>/dev/null | head -n 1)
    
    # 2. Check for individual service backups
    LATEST_N8N_BACKUP=$(find_latest_backup_in_dir "n8n")
    LATEST_SUPABASE_BACKUP=$(find_latest_backup_in_dir "supabase")
    LATEST_NPM_BACKUP=$(find_latest_backup_in_dir "npm")
    LATEST_CLOUDFLARED_BACKUP=$(find_latest_backup_in_dir "cloudflared")
    LATEST_PORTAINER_BACKUP=$(find_latest_backup_in_dir "portainer")
    
    # Determine what to use
    # Logic: 
    # If a global archive is newer than individual folders, suggest that?
    # Or just show what we found.
    # For now, let's prioritize individual folders if they exist and are recent. 
    # Actually, simpler: check timestamps.
    
    local archive_ts=0
    if [ -n "$LATEST_ARCHIVE" ]; then
        # stat syntax differs on Mac vs Linux
        if date --version &>/dev/null; then # GNU
             archive_ts=$(stat -c %Y "$LATEST_ARCHIVE")
        else # BSD/Mac
             archive_ts=$(stat -f %m "$LATEST_ARCHIVE")
        fi
        print_info "Found archive: $(basename "$LATEST_ARCHIVE")"
    fi

    # Check if we have any individual folder backups
    local has_folders=false
    if [ -n "$LATEST_N8N_BACKUP" ] || [ -n "$LATEST_SUPABASE_BACKUP" ] || [ -n "$LATEST_NPM_BACKUP" ] || [ -n "$LATEST_CLOUDFLARED_BACKUP" ] || [ -n "$LATEST_PORTAINER_BACKUP" ]; then
        has_folders=true
    fi
    
    if [ "$has_folders" = "false" ] && [ -z "$LATEST_ARCHIVE" ]; then
        print_error "No backups found in $BACKUPS_DIR"
        exit 1
    fi
    
    # Decision Time
    # If we have both, we need to decide or ask.
    # Simpler approach: 
    # If archive is significantly newer (e.g. > 1 min) than folders, prefer archive.
    # Otherwise prefer folders (faster, no unzip). 
    
    # Actually, let's just ask the user if there's ambiguity?
    # Or, as per requirements: "takes the freshest backup".
    
    # Let's compare archive timestamp vs max folder timestamp
    local max_folder_ts=0
    
    for backup in "$LATEST_N8N_BACKUP" "$LATEST_SUPABASE_BACKUP" "$LATEST_NPM_BACKUP" "$LATEST_CLOUDFLARED_BACKUP" "$LATEST_PORTAINER_BACKUP"; do
        if [ -n "$backup" ]; then
             local ts=0
             if date --version &>/dev/null; then ts=$(stat -c %Y "$backup"); else ts=$(stat -f %m "$backup"); fi
             if [ "$ts" -gt "$max_folder_ts" ]; then max_folder_ts=$ts; fi
        fi
    done
    
    if [ -n "$LATEST_ARCHIVE" ] && [ "$archive_ts" -gt "$max_folder_ts" ]; then
        SOURCE_TYPE="archive"
        SELECTED_ARCHIVE="$LATEST_ARCHIVE"
        print_info "Using most recent source: Archive $(basename "$LATEST_ARCHIVE")"
    else
        SOURCE_TYPE="folders"
        print_info "Using most recent source: Individual Backup Folders"
        [ -n "$LATEST_N8N_BACKUP" ] && echo "  - n8n: $(basename "$LATEST_N8N_BACKUP")"
        [ -n "$LATEST_SUPABASE_BACKUP" ] && echo "  - Supabase: $(basename "$LATEST_SUPABASE_BACKUP")"
        [ -n "$LATEST_NPM_BACKUP" ] && echo "  - NPM: $(basename "$LATEST_NPM_BACKUP")"
        [ -n "$LATEST_CLOUDFLARED_BACKUP" ] && echo "  - Cloudflared: $(basename "$LATEST_CLOUDFLARED_BACKUP")"
        [ -n "$LATEST_PORTAINER_BACKUP" ] && echo "  - Portainer: $(basename "$LATEST_PORTAINER_BACKUP")"
    fi
}

# ============================================================================
# UI Logic
# ============================================================================

select_services() {
    local cmd=""
    if command -v whiptail &>/dev/null; then cmd="whiptail"; elif command -v dialog &>/dev/null; then cmd="dialog"; fi
    
    # Construct options based on availability
    local options=()
    local available_count=0
    
    # Helper to check availability
    is_available() {
        if [ "$SOURCE_TYPE" = "archive" ]; then return 0; fi # Assume archive has everything or we can't easily peek without extracting
        [ -n "$1" ]
    }
    
    if is_available "$LATEST_N8N_BACKUP"; then
        options+=("n8n" "Restore n8n" OFF)
        available_count=$((available_count+1))
    fi
    
    if is_available "$LATEST_SUPABASE_BACKUP"; then
        options+=("supabase" "Restore Supabase" OFF)
        available_count=$((available_count+1))
    fi
    
    if is_available "$LATEST_NPM_BACKUP"; then
        options+=("npm" "Restore NPM" OFF)
        available_count=$((available_count+1))
    fi
    
    if is_available "$LATEST_CLOUDFLARED_BACKUP"; then
        options+=("cloudflared" "Restore Cloudflared" OFF)
        available_count=$((available_count+1))
    fi
    
    if is_available "$LATEST_PORTAINER_BACKUP"; then
        options+=("portainer" "Restore Portainer" OFF)
        available_count=$((available_count+1))
    fi
    
    if [ "$available_count" -eq 0 ]; then
        print_error "No restoreable services found."
        exit 1
    fi
    
    local selected
    if [ -n "$cmd" ]; then 
        if [ "$cmd" = "whiptail" ]; then
            selected=$(whiptail --title "Stack Restore" --checklist "Select services to restore:" 20 70 10 "${options[@]}" 3>&1 1>&2 2>&3)
        else
            selected=$(dialog --stdout --title "Stack Restore" --checklist "Select services to restore:" 20 70 10 "${options[@]}")
        fi
    else
        # Fallback to simple read
        print_info "Interactive menu missing. Please select manually."
        selected=""
        if is_available "$LATEST_N8N_BACKUP"; then read -p "Restore n8n? [y/N] " r; [[ "$r" =~ ^[Yy] ]] && selected="$selected n8n"; fi
        if is_available "$LATEST_SUPABASE_BACKUP"; then read -p "Restore Supabase? [y/N] " r; [[ "$r" =~ ^[Yy] ]] && selected="$selected supabase"; fi
        if is_available "$LATEST_NPM_BACKUP"; then read -p "Restore NPM? [y/N] " r; [[ "$r" =~ ^[Yy] ]] && selected="$selected npm"; fi
        if is_available "$LATEST_CLOUDFLARED_BACKUP"; then read -p "Restore Cloudflared? [y/N] " r; [[ "$r" =~ ^[Yy] ]] && selected="$selected cloudflared"; fi
        if is_available "$LATEST_PORTAINER_BACKUP"; then read -p "Restore Portainer? [y/N] " r; [[ "$r" =~ ^[Yy] ]] && selected="$selected portainer"; fi
    fi
    
    if [ -z "$selected" ]; then
        print_error "No services selected."
        exit 0
    fi
    
    for service in $selected; do
        case $service in
            \"n8n\"|n8n) RESTORE_N8N=true ;;
            \"supabase\"|supabase) RESTORE_SUPABASE=true ;;
            \"npm\"|npm) RESTORE_NPM=true ;;
            \"cloudflared\"|cloudflared) RESTORE_CLOUDFLARED=true ;;
            \"portainer\"|portainer) RESTORE_PORTAINER=true ;;
        esac
    done
}

# ============================================================================
# Restore Actions
# ============================================================================

stop_services() {
    print_header "Stopping Services for Restore"
    
    # We stop ALL services if possible to prevent conflicts/locks, 
    # but strictly only the ones we are restoring + dependencies.
    # Simplify: Ask user if we can stop everything relevant.
    
    local services_to_stop=""
    if $RESTORE_N8N; then services_to_stop="$services_to_stop n8n"; fi
    if $RESTORE_SUPABASE; then services_to_stop="$services_to_stop supabase"; fi
    if $RESTORE_NPM; then services_to_stop="$services_to_stop npm"; fi
    if $RESTORE_CLOUDFLARED; then services_to_stop="$services_to_stop cloudflared"; fi
    if $RESTORE_PORTAINER; then services_to_stop="$services_to_stop portainer"; fi
    
    # Check dependencies
    # n8n depends on supabase (db). If restoring n8n, we might need supabase down if we are restoring db? 
    # Actually, if we restore n8n volume, we just need n8n down. 
    # But if we restore Supabase DB, we definitely need Supabase down, and n8n will crash if running.
    if $RESTORE_SUPABASE && [[ "$services_to_stop" != *"n8n"* ]]; then
        print_warning "Restoring Supabase will likely disrupt n8n."
        read -p "Stop n8n as well? [Y/n] " r
        if [[ ! "$r" =~ ^[Nn] ]]; then services_to_stop="$services_to_stop n8n"; fi
    fi

    # Execute stops
    # Just generic down on directories
    if [[ "$services_to_stop" == *"n8n"* ]];   then cd "$N8N_DIR" && docker compose down; fi
    if [[ "$services_to_stop" == *"supabase"* ]]; then cd "$SUPABASE_DIR" && docker compose down; fi
    if [[ "$services_to_stop" == *"npm"* ]];   then cd "$NPM_DIR" && docker compose down; fi
    if [[ "$services_to_stop" == *"cloudflared"* ]]; then cd "$CLOUDFLARED_DIR" && docker compose down; fi
    if [[ "$services_to_stop" == *"portainer"* ]]; then cd "$PORTAINER_DIR" && docker compose down; fi
}

clean_volume() {
    local volume_name=$1
    if docker volume inspect "$volume_name" &>/dev/null; then
        print_info "Removing existing volume: $volume_name"
        docker volume rm "$volume_name" || { 
            print_warning "Could not remove volume $volume_name. It might be in use."
            return 1
        }
    fi
}

# Helper: Restore logical dump
restore_n8n_db_dump() {
    local dump_file="$1"
    
    print_info "Logical dump found: $(basename "$dump_file")"
    
    print_info "Attempting logical DB restore to n8n-db..."
    
    # Check if n8n-db is running
    local db_container="n8n-db"
    local needs_stop=false
    
    if ! docker ps | grep -q "$db_container"; then
        print_info "Starting n8n-db temporarily..."
        if [ -d "$N8N_DIR" ]; then
            cd "$N8N_DIR"
            # Start only n8n-db
            docker compose up -d n8n-db
            
            # Wait for health
            echo -n "Waiting for DB to accept connections..."
            local retries=30
            while [ $retries -gt 0 ]; do
                # Load env for user check
                source .env 2>/dev/null || true
                local db_user=${POSTGRES_USER:-postgres_user}
                
                if docker exec "$db_container" pg_isready -U "$db_user" >/dev/null 2>&1; then
                    echo " OK"
                    break
                fi
                echo -n "."
                sleep 2
                retries=$((retries - 1))
            done
            
            if [ $retries -eq 0 ]; then
                print_error "Database took too long to start. Skipping logical restore."
                return 1
            fi
            
            needs_stop=true
        else
             print_error "n8n directory not found. Cannot start DB."
             return 1
        fi
    fi
    
    # Perform Restore
    print_info "Restoring n8n database from dump..."
    
    source "$N8N_DIR/.env" 2>/dev/null || true
    local db_user=${POSTGRES_USER:-postgres_user}
    local db_name=${POSTGRES_DB:-n8n}
    
    # Drop and create DB (WARNING: destructive)
    # Since we are restoring full DB dump probably
    
    if docker exec -i "$db_container" psql -U "$db_user" -d postgres -c "DROP DATABASE IF EXISTS \"$db_name\"; CREATE DATABASE \"$db_name\";" >/dev/null; then
         # Restore data
         if docker exec -i "$db_container" psql -U "$db_user" -d "$db_name" < "$dump_file" >/dev/null; then
             print_success "Logical backup restored successfully."
         else
             print_error "Failed to import SQL dump."
         fi
    else
         print_error "Failed to recreate database."
    fi
    
    if [ "$needs_stop" = "true" ]; then
        print_info "Stopping temporary n8n-db..."
        cd "$N8N_DIR" && docker compose stop n8n-db
    fi
}

restore_n8n() {
    local src_path="$1" # Folder containing files/ and .env and .tar.gz
    print_header "Restoring n8n"
    
    if [ ! -d "$src_path" ]; then print_error "Source not found: $src_path"; return; fi
    
    # Configs
    print_info "Restoring files..."
    cp -r "$src_path/.env" "$N8N_DIR/.env"
    mkdir -p "$N8N_DIR"
    if [ -d "$src_path/files" ]; then
        print_info "Restoring files directory..."
        rm -rf "$N8N_DIR/files"
        cp -R "$src_path/files" "$N8N_DIR/"
    fi
    
    # Volume
    # Volume: n8n_data
    local vol_file="$src_path/n8n_data.tar.gz"
    if [ -f "$vol_file" ]; then
        clean_volume "n8n_n8n_data"
        print_info "Restoring n8n_data volume..."
        docker volume create --label com.docker.compose.project=n8n --label com.docker.compose.volume=n8n_data n8n_n8n_data
        docker run --rm \
            -v n8n_n8n_data:/volume \
            -v "$(dirname "$vol_file")":/backup \
            alpine \
            tar -xzf "/backup/$(basename "$vol_file")" -C /volume
        print_success "n8n_data restored"
    else
        print_warning "n8n_data volume backup not found at $vol_file"
    fi
    
    # Volume: db_storage
    local db_vol_file="$src_path/n8n_db_storage.tar.gz"
    if [ -f "$db_vol_file" ]; then
        clean_volume "n8n_db_storage"
        print_info "Restoring n8n_db_storage volume..."
         # Assuming project name 'n8n' from docker-compose.yml location
        docker volume create --label com.docker.compose.project=n8n --label com.docker.compose.volume=db_storage n8n_db_storage
        docker run --rm \
            -v n8n_db_storage:/volume \
            -v "$(dirname "$db_vol_file")":/backup \
            alpine \
            tar -xzf "/backup/$(basename "$db_vol_file")" -C /volume
        print_success "n8n_db_storage restored"
    fi

    # Logical DB Restore
    local dump_file="$src_path/n8n_db_dump.sql"
    if [ -f "$dump_file" ]; then
        restore_n8n_db_dump "$dump_file"
    fi
}

restore_supabase() {
    local src_path="$1"
    print_header "Restoring Supabase"
    
    # Configs
    print_info "Restoring files..."
    cp "$src_path/.env" "$SUPABASE_DIR/.env"
    cp "$src_path/docker-compose.yml" "$SUPABASE_DIR/docker-compose.yml"
    
    # Volumes (bind mounts)
    if [ -d "$src_path/volumes" ]; then
        print_info "Restoring volumes directory..."
        # Warning: This overwrites
        rm -rf "$SUPABASE_DIR/volumes"
        cp -R "$src_path/volumes" "$SUPABASE_DIR/"
        print_success "Supabase restored"
    else
        print_warning "Volumes backup not found at $src_path/volumes"
    fi
}

restore_npm() {
    local src_path="$1"
    print_header "Restoring NPM"
    
    if [ -d "$src_path/data" ]; then
        print_info "Restoring data..."
        rm -rf "$NPM_DIR/data"
        cp -R "$src_path/data" "$NPM_DIR/"
    fi
    
    if [ -d "$src_path/letsencrypt" ]; then
        print_info "Restoring certificates..."
        rm -rf "$NPM_DIR/letsencrypt"
        cp -R "$src_path/letsencrypt" "$NPM_DIR/"
    fi
    print_success "NPM restored"
}

restore_cloudflared() {
    local src_path="$1"
    print_header "Restoring Cloudflared"
    
    print_info "Restoring .env..."
    cp "$src_path/.env" "$CLOUDFLARED_DIR/.env"
    print_success "Cloudflared restored"
}

restore_portainer() {
    local src_path="$1"
    print_header "Restoring Portainer"
    
    local vol_file="$src_path/portainer_data.tar.gz"
    if [ -f "$vol_file" ]; then
        clean_volume "portainer_data"
        print_info "Restoring portainer_data volume..."
        # Create volume with labels so Docker Compose recognizes it
        docker volume create --label com.docker.compose.project=portainer --label com.docker.compose.volume=portainer_data portainer_data
        docker run --rm \
            -v portainer_data:/volume \
            -v "$(dirname "$vol_file")":/backup \
            alpine \
            tar -xzf "/backup/$(basename "$vol_file")" -C /volume
        print_success "Portainer restored"
    else
        print_warning "Volume backup not found at $vol_file"
    fi
}

start_services() {
    print_header "Restarting Services"
    echo -e "${YELLOW}Please start services manually using ./start-stack.sh or specific prompts${NC}"
    # Or just offer?
    read -p "Start stack now? [Y/n] " r
    if [[ ! "$r" =~ ^[Nn] ]]; then
        "$PROJECT_ROOT/start-stack.sh"
    fi
}

# ============================================================================
# Main
# ============================================================================

main() {
    print_header "n8n Stack Restore"
    
    # 0. Check dependencies
    check_dependencies
    
    # 1. Scan for backups
    find_backups
    
    # 2. Select Services
    select_services
    
    # 3. Confirmation
    echo ""
    print_warning "This process will OVERWRITE current data for selected services."
    read -p "Are you absolutely sure? [Type 'yes' to confirm]: " confirm
    if [ "$confirm" != "yes" ]; then
        echo "Aborted."
        exit 0
    fi
    
    # 4. Prepare Source
    if [ "$SOURCE_TYPE" = "archive" ]; then
        print_info "Extracting archive to temp location: $TEMP_RESTORE_DIR"
        mkdir -p "$TEMP_RESTORE_DIR"
        tar -xzf "$SELECTED_ARCHIVE" -C "$TEMP_RESTORE_DIR"
        
        # Determine subdirectory names by looking inside
        # The archive creation uses relative paths like "n8n/n8n_backup_..." or "supabase/..."
        # So inside temp_restore we should have n8n/, supabase/, etc.
        # But we need to know the specific timestamped directory name.
        
        # Re-resolve paths inside temp dir
        resolve_temp_path() {
            local service=$1
            # Find the directory inside "$TEMP_RESTORE_DIR/$service"
            if [ -d "$TEMP_RESTORE_DIR/$service" ]; then
                local found=$(ls -d "$TEMP_RESTORE_DIR/$service"/*_backup_* 2>/dev/null | head -n 1)
                echo "$found"
            fi
        }
        
        N8N_SRC=$(resolve_temp_path "n8n")
        SUPABASE_SRC=$(resolve_temp_path "supabase")
        NPM_SRC=$(resolve_temp_path "npm")
        CLOUDFLARED_SRC=$(resolve_temp_path "cloudflared")
        PORTAINER_SRC=$(resolve_temp_path "portainer")
        
    else
        # Direct folders
        N8N_SRC="$LATEST_N8N_BACKUP"
        SUPABASE_SRC="$LATEST_SUPABASE_BACKUP"
        NPM_SRC="$LATEST_NPM_BACKUP"
        CLOUDFLARED_SRC="$LATEST_CLOUDFLARED_BACKUP"
        PORTAINER_SRC="$LATEST_PORTAINER_BACKUP"
    fi
    
    # 5. Stop Services
    stop_services
    
    # 6. Execute Restore
    if $RESTORE_N8N; then restore_n8n "$N8N_SRC"; fi
    if $RESTORE_SUPABASE; then restore_supabase "$SUPABASE_SRC"; fi
    if $RESTORE_NPM; then restore_npm "$NPM_SRC"; fi
    if $RESTORE_CLOUDFLARED; then restore_cloudflared "$CLOUDFLARED_SRC"; fi
    if $RESTORE_PORTAINER; then restore_portainer "$PORTAINER_SRC"; fi
    
    # 7. Cleanup
    if [ -d "$TEMP_RESTORE_DIR" ]; then
        print_info "Cleaning up temp files..."
        rm -rf "$TEMP_RESTORE_DIR"
    fi
    
    print_header "Restore Complete"
    
    # 8. Start Services
    start_services
}

main
