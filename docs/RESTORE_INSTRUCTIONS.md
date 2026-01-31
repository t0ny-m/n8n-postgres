# Restore Instructions

This guide explains how to restore your n8n-stack services from a backup.

> [!WARNING]
> Restoring data is a destructive operation. Existing data in the services you select will be overwritten by the backup data.

## Automated Restore

The stack includes a restore script that simplifies the process by automatically finding the latest backup and handling file placement and volume restoration.

### Prerequisites
- Docker and Docker Compose installed.
- Previous backups located in `backups/` directory (either as folders or `.tar.gz` archives).

### Running the Script

1. Open a terminal in the project root.
2. Run the restore script:

```bash
./scripts/restore/restore-stack.sh
```

### How it Works

1. **Discovery**: The script scans the `backups/` directory.
   - It looks for a global archive (`n8n_stack_backup_....tar.gz`).
   - It looks for individual service backup folders (e.g., `backups/n8n/n8n_backup_...`).
   - It prioritizes the "freshest" source (comparing timestamps).

2. **Selection**: You will be prompted to select which services you want to restore.
   - Only services found in the backup source will be available.

3. **Confirmation**: You must type `yes` to confirm the overwrite.

4. **Restoration**:
   - The script will stop the relevant services.
   - Files (`.env`, config files) are copied to their respective locations.
   - Data volumes (for n8n and Portainer) are restored using a temporary helper container.
   - Supabase `volumes` directory is replaced.
   - NPM data is replaced.

5. **Restart**: The script offers to restart the stack when finished.

## Manual Restore

If you cannot use the script, you can restore manually. See the "Migration Guide" section in [BACKUP_INSTRUCTIONS.md](BACKUP_INSTRUCTIONS.md) for details on where files need to go.

### Troubleshooting

- **Volume in use error**: If the script fails to remove a volume, ensure all containers using it are stopped. `docker ps` to check running containers.
- **Permission denied**: Ensure you are running the script with sufficient permissions (user in `docker` group or check file ownership).
