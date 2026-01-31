# n8n Stack - Installation Guide

Complete self-hosted stack with n8n, Supabase, Nginx Proxy Manager, and Cloudflare Tunnel.

## Features

- **n8n** - Workflow automation platform
- **Supabase** - Open-source Firebase alternative (PostgreSQL, Auth, Storage, Realtime)
- **Nginx Proxy Manager** - Easy SSL and reverse proxy management (optional)
- **Cloudflare Tunnel** - Secure tunnel without exposing ports for Local hosted (optional)
- **Portainer** - Docker container management UI (optional)

## Prerequisites

- **Docker Desktop** (macOS/Windows) or **Docker Engine** (Linux)
- **Git**
- **2GB+ RAM** recommended

### Install Docker

#### Linux
```bash
sudo systemctl enable ssh
```
SSH will start automatically every time the system boots

```bash
sudo apt update && sudo apt upgrade -y
curl -fsSL https://get.docker.com | sudo sh
docker --version
sudo usermod -aG docker $USER
newgrp docker
```

**Note**

The Docker service starts automatically after installation. To verify that Docker is running, use:
```bash
sudo systemctl status docker
```
Some systems may have this behavior disabled and will require a manual start:
```bash
sudo systemctl start docker
```

Verify that the installation is successful by running the hello-world image:
```bash
sudo docker run hello-world
```
This command downloads a test image and runs it in a container. When the container runs, it prints a confirmation message and exits.

#### macOS
Download from: https://docs.docker.com/desktop/install/mac-install/

Or via Homebrew:
```bash
brew install --cask docker
```

#### Windows
Download from: https://docs.docker.com/desktop/install/windows-install/

Make sure WSL2 backend is enabled.

## Installation

### 1. Clone the repository

```bash
git clone https://github.com/t0ny-m/n8n-stack.git
cd n8n-stack
```

### 2. Setup environment files

```
cp n8n/.env.example n8n/.env
cp proxy/cloudflared/.env.example proxy/cloudflared/.env
cp supabase/.env.example supabase/.env
```

#### n8n configuration

```bash
cd n8n
nano .env  # or use your preferred editor
```

Edit `n8n/.env` and set:
- `N8N_HOST`, `DOMAIN_NAME`, `WEBHOOK_URL` - your domain/subdomain
- `N8N_ENCRYPTION_KEY` - generate with: `openssl rand -hex 16`
- `DB_POSTGRESDB_PASSWORD` - generate with: `openssl rand -hex 32`

#### Supabase configuration

```bash
cd supabase/docker
nano .env  # or use your preferred editor
```

Edit `supabase/docker/.env` and set:
**Required settings:**
- `POSTGRES_PASSWORD` - generate with: `openssl rand -hex 32`
- `JWT_SECRET`, `ANON_KEY`, `SERVICE_ROLE_KEY` - generate following: https://supabase.com/docs/guides/self-hosting/docker#generate-api-keys
- `DASHBOARD_PASSWORD` - you password to supabase dashboard
- `SECRET_KEY_BASE` - generate with: `openssl rand -hex 32`
- `VAULT_ENC_KEY` - generate with: `openssl rand -base64 32 | cut -c1-32`
- `PG_META_CRYPTO_KEY` - generate with: `openssl rand -hex 32`
- `SITE_URL`, `API_EXTERNAL_URL`, `SUPABASE_PUBLIC_URL` -your domain/subdomain

**Important:** Keep these keys secure and never commit them to git!

#### Nginx Proxy Manager (optional)

```bash
cd proxy/npm
```
- No environment variables required for basic setup

#### Cloudflared Tunnel (optional)

```bash
cd proxy/cloudflared
nano .env  # or use your preferred editor
```

Set `CLOUDFLARE_TUNNEL_TOKEN` from Cloudflare Zero Trust Dashboard.
1. Go to https://one.dash.cloudflare.com/
2. Navigate to Networks → Tunnels
3. Create a tunnel and copy the token

**Important:** Keep all generated keys secure and never commit them to git!

### 3. Start the stack

```bash
cd n8n-stack # cd ../.. to back to n8n-stack root from n8n-stack/proxy/cloudflared
chmod +x start-stack.sh
./start-stack.sh
```

Or from scripts directory:
```bash
cd n8n-stack/scripts/manage
chmod +x start-stack.sh
./start-stack.sh
```

**The script will automatically:**
1. Check if Docker is running
2. Create network if needed
3. Let you choose which services to start
4. Start services in correct order

#### Interactive menu (if whiptail/dialog available):
```
┌─────────── Stack Startup ───────────┐
│ Select services (Space=select):     │
│                                     │
│ [X] n8n                             │
│ [ ] Supabase (full stack)           │
│ [X] Nginx Proxy Manager             │
│ [ ] Cloudflared Tunnel              │
│ [ ] Portainer                       │
│                                     │
│         <OK>        <Cancel>        │
└─────────────────────────────────────┘
```

#### Simple mode (without whiptail):
```
Start n8n? [y/N]: y
Start Supabase (full stack)? [y/N]: n
Start Nginx Proxy Manager? [y/N]: y
Start Cloudflared Tunnel? [y/N]: n
Start Portainer? [y/N]: n
```

### 4. Access services

After startup, access:
- **n8n**: http://localhost:5678
- **Supabase Studio**: http://localhost:8000
- **Nginx Proxy Manager**: http://localhost:81

## Usage

### Start services

```bash
./start-stack.sh
```

Interactive menu will let you choose which services to start.

### Stop services

```bash
# Stop n8n
cd n8n && docker compose down

# Stop Supabase
cd supabase/docker && docker compose down

# Stop NPM
cd proxy/npm && docker compose down
```

### View logs

```bash
# n8n logs
docker logs n8n -f

# Supabase DB logs
docker logs supabase-db -f
```

### Restart a service

```bash
cd n8n
docker compose restart
```

### Update services

```bash
# Pull latest images
cd n8n
docker compose pull

# Recreate containers
docker compose up -d

# Same for other services
cd ../supabase/docker
docker compose pull
docker compose up -d
```

## Backup & Restore

### Backup n8n workflows

```bash
# Export all workflows
docker exec n8n n8n export:workflow --all --output=/backup/workflows-$(date +%Y%m%d).json

# Backup to local machine
docker cp n8n:/backup ./backups/n8n/
```

### Backup Supabase database

```bash
# Create backup
docker exec supabase-db pg_dump -U postgres postgres > backups/supabase/backup-$(date +%Y%m%d).sql
```

### Backup n8n database

```bash
# Create backup
docker exec n8n-db pg_dump -U postgres_user n8n > backups/n8n/n8n-db-$(date +%Y%m%d).sql
```

### Restore database

```bash
# Restore full database
docker exec -i supabase-db psql -U postgres postgres < backups/supabase/backup-20260124.sql

# Restore n8n database
docker exec -i n8n-db psql -U postgres_user -d n8n < backups/n8n/n8n-db-20260124.sql
```

## Troubleshooting

### Docker not running

**Linux:**
```bash
sudo systemctl start docker
sudo systemctl enable docker
```

**macOS/Windows:**
- Make sure Docker Desktop application is running
- Look for Docker icon in system tray/menu bar
- Restart Docker Desktop if needed

### Port conflicts

If ports 5678, 8000, 80, 443, or 81 are already in use, edit the respective `docker-compose.yml` files to change port mappings.

### n8n can't connect to database

Make sure:
1. Supabase is running: `docker ps | grep supabase-db`
2. Database is healthy: `docker inspect supabase-db --format='{{.State.Health.Status}}'`
3. Passwords in `n8n/.env` and `supabase/docker/.env` match

### Network issues

Recreate network:
```bash
docker network rm n8n-stack-network
docker network create n8n-stack-network
```
### Container keeps restarting

**Check logs:**
```bash
docker logs <container-name> --tail 100
```

**Common causes:**
- Missing or incorrect `.env` configuration
- Port already in use
- Insufficient memory (increase Docker memory limit)
- Database not ready (n8n waiting for Supabase)

### Out of memory (t3.micro/small instances)

**Enable swap:**
```bash
sudo fallocate -l 4G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile

# Make permanent
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
echo 'vm.swappiness=10' | sudo tee -a /etc/sysctl.conf
```

**Reduce memory limits in docker-compose.yml:**
```yaml
deploy:
  resources:
    limits:
      memory: 512M  # Reduce from 1024M
```

**Run minimal services:**
- Start only n8n (minimal Supabase will start automatically)
- Stop unused Supabase services when not needed

## Architecture

```
      ┌───────────┴───────────┐
      │                       │
 ┌────┴─────┐           ┌─────┴──────┐
 │   n8n    │ :5678     │  Supabase  │ :8000
 │          │           │            │ :3000
 │ ┌──────┐ │           │ ┌────────┐ │
 │ │n8n-db│◀┼────────── │ │   DB   │ │
 │ └──────┘ │           │ └────────┘ │
 └──────────┘           └────────────┘
           │
           └─────────────────┐
               n8n-stack-network
```

### Component Relationships

- **n8n** uses its own **n8n-db** (PostgreSQL 16)
- **Supabase** (Optional) is now completely independent
- **n8n-db** is initialized automatically using `init-data.sh`
- **NPM** and **Cloudflared** are optional for reverse proxy/SSL
- All services communicate via `n8n-stack-network` Docker network

## Project Structure

```
n8n-stack/
├── start-stack.sh              # Main startup script
├── README.md
├── MIGRATION_GUIDE.md          # Migration from Supabase to n8n-PG
├── n8n/
│   ├── docker-compose.yml
│   ├── .env.example
│   ├── .env                    # Create from .env.example
│   ├── files/
│   └── backup/
├── supabase/
│   ├── docker-compose.yml
│   ├── .env.example
│   ├── .env                # Create from .env.example
│   └── volumes/
├── proxy/
│   ├── npm/
│   │   ├── letsencrypt/
│   │   ├── docker-compose.yml
│   │   └── .env.example
│   └── cloudflared/
│       ├── docker-compose.yml
│       ├── .env.example
│       └── .env                # Create from .env.example
├── portainer/                  # Optional
│   └── docker-compose.yml
└── scripts/
    └── manage/
        └── start-stack.sh      # Symlink to root script
```

## Resources

- [n8n Documentation](https://docs.n8n.io/)
- [Supabase Self-Hosting](https://supabase.com/docs/guides/self-hosting)
- [Nginx Proxy Manager](https://nginxproxymanager.com/)
- [Cloudflare Tunnels](https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/)

## Security Best Practices

1. **Change default passwords** immediately after first login
2. **Use strong encryption keys** (generated with `openssl rand`)
3. **Never commit `.env` files** to git (they're in `.gitignore`)
4. **Enable firewall** if exposing ports directly:
```bash
# Linux (ufw)
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw enable
```
5. **Use Cloudflare Tunnel** instead of exposing ports when possible
6. **Regular backups** of databases and n8n workflows
7. **Update regularly** by pulling latest Docker images

## License

MIT

## Support

For issues and questions:
- Open an issue on GitHub
- Check [n8n community forum](https://community.n8n.io/)
- Check [Supabase discussions](https://github.com/supabase/supabase/discussions)
