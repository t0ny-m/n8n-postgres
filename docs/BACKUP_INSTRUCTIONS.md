# Backup and Migration Guide

This guide explains how to back up your n8n-stack and migrate it to a new instance.

## 1. Quick Backup

The easiest way to backup is using the included script.

```bash
./scripts/manage/backup-stack.sh
```

- Select the services you want to backup.
- Choose whether to stop services (recommended for database consistency).
- The script will create individual backup folders in `backups/<service>/`.
- At the end, you can choose to create a single `.tar.gz` archive of all created backups.

## 2. Manual Backup

If you prefer to backup manually, here is what you need to save for each service.

### n8n
- **Location**: `n8n/`
- **Files**: `.env`
- **Directories**: `files/`
- **Data Volume**: `n8n_data` (Named Volume)
  - To backup: `docker run --rm -v n8n_data:/volume -v $(pwd):/backup alpine tar -czf /backup/n8n_data.tar.gz -C /volume .`
- **Logical Backup**: The script automatically tries to create `n8n_schema_dump.sql` by running `pg_dump` against the `supabase-db` container before stopping services.

### Supabase
- **Location**: `supabase/`
- **Files**: `.env`, `docker-compose.yml`
- **Directories**: `volumes/` (Contains database, storage, functions)
  - To backup: `cp -R supabase/volumes /path/to/backup/`

### Nginx Proxy Manager (NPM)
- **Location**: `proxy/npm/`
- **Directories**: `data/`, `letsencrypt/`

### Cloudflared
- **Location**: `proxy/cloudflared/`
- **Files**: `.env` (Contains Tunnel Token)

### Portainer
- **Location**: `portainer/`
- **Data Volume**: `portainer_data` (Named Volume)
  - To backup: `docker run --rm -v portainer_data:/volume -v $(pwd):/backup alpine tar -czf /backup/portainer_data.tar.gz -C /volume .`

---

## 3. Migration Guide

Follow these steps to move your stack to a new server.

### Step 1: Prepare New Server
1. Install Docker and Docker Compose.
2. Clone this repository to the new server.
   ```bash
   git clone <your-repo-url> n8n-stack
   cd n8n-stack
   ```

### Step 2: Transfer Backup
Copy your backup archive (`n8n_stack_backup_YYYYMMDD_....tar.gz`) to the new server.

### Step 3: Restore Data
1. Extract the backup archive.
   ```bash
   mkdir temp_restore
   tar -xzf n8n_stack_backup_....tar.gz -C temp_restore
   ```

2. **Restore n8n**
   - Copy `.env` and `files/` to `n8n/`.
   - Restore volume:
     ```bash
     docker volume create n8n_data
     docker run --rm -v n8n_data:/volume -v $(pwd)/temp_restore/n8n:/backup alpine tar -xzf /backup/n8n_data.tar.gz -C /volume
     ```

3. **Restore Supabase**
   - Copy `.env` and `docker-compose.yml` to `supabase/`.
   - Copy `volumes` directory to `supabase/volumes`.

4. **Restore NPM**
   - Copy `data` and `letsencrypt` directories to `proxy/npm/`.

5. **Restore Cloudflared**
   - Copy `.env` to `proxy/cloudflared/`.

6. **Restore Portainer**
   - Restore volume:
     ```bash
     docker volume create portainer_data
     docker run --rm -v portainer_data:/volume -v $(pwd)/temp_restore/portainer:/backup alpine tar -xzf /backup/portainer_data.tar.gz -C /volume
     ```

### Step 4: Start Stack
Run the start script to launch your services.

```bash
./start-stack.sh
```
