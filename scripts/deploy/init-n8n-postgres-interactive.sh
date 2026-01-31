#!/usr/bin/env bash
set -e

# ------------------------------------------------------------
# n8n + Supabase Postgres initialization (OPERATOR VERSION)
# ------------------------------------------------------------

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
N8N_ENV_FILE="$PROJECT_ROOT/n8n/.env"
N8N_COMPOSE_DIR="$PROJECT_ROOT/n8n"
DB_CONTAINER="supabase-db"

print_line() { echo "------------------------------------------------------------"; }

print_line
echo "n8n + Supabase Postgres initialization"
print_line

# ------------------------------------------------------------
# 0. Check supabase-db container
# ------------------------------------------------------------
if ! docker inspect "$DB_CONTAINER" >/dev/null 2>&1; then
  echo "ERROR: container '$DB_CONTAINER' not found."
  echo "Start Supabase first: cd supabase/docker && docker compose up -d"
  exit 1
fi

echo "Waiting for $DB_CONTAINER to become healthy..."

for i in {1..60}; do
  STATUS=$(docker inspect -f '{{.State.Health.Status}}' "$DB_CONTAINER" 2>/dev/null || echo "unknown")
  if [ "$STATUS" = "healthy" ]; then
    echo "DB is healthy."
    break
  fi
  sleep 2
done

if [ "$STATUS" != "healthy" ]; then
  echo "ERROR: DB did not become healthy in time."
  exit 1
fi

# ------------------------------------------------------------
# 1. Choose password method
# ------------------------------------------------------------
print_line
echo "Choose password option:"
echo "  1) Generate password automatically (openssl rand -hex 32)"
echo "  2) Enter password manually"
read -rp "Select [1/2]: " PASSWORD_MODE

case "$PASSWORD_MODE" in
  1)
    command -v openssl >/dev/null || { echo "ERROR: openssl not found"; exit 1; }
    N8N_DB_PASSWORD="$(openssl rand -hex 32)"
    echo "Generated password:"
    echo "$N8N_DB_PASSWORD"
    ;;
  2)
    read -rsp "Enter password for Postgres user 'n8n': " N8N_DB_PASSWORD
    echo
    [ -z "$N8N_DB_PASSWORD" ] && { echo "ERROR: empty password"; exit 1; }
    ;;
  *)
    echo "ERROR: Invalid selection"
    exit 1
    ;;
esac

# ------------------------------------------------------------
# 2. Detect whether user exists
# ------------------------------------------------------------
USER_EXISTS=$(docker exec -i "$DB_CONTAINER" \
  psql -U postgres -d postgres -tAc \
  "SELECT 1 FROM pg_roles WHERE rolname='n8n';")

ROTATE_PASSWORD=false
UPDATE_ENV=false

if [ "$USER_EXISTS" = "1" ]; then
  print_line
  echo "Postgres user 'n8n' already exists."
  read -rp "Update password for user 'n8n'? [y/N]: " CONFIRM
  if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
    ROTATE_PASSWORD=true
    UPDATE_ENV=true
  else
    echo "Skipping password update."
  fi
else
  echo "Postgres user 'n8n' does not exist. Clean install mode."
  UPDATE_ENV=true
fi

# ------------------------------------------------------------
# 3. Create / update user
# ------------------------------------------------------------
if [ "$USER_EXISTS" != "1" ]; then
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres <<EOF
CREATE USER n8n WITH PASSWORD '${N8N_DB_PASSWORD}';
EOF
fi

if [ "$ROTATE_PASSWORD" = true ]; then
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres <<EOF
ALTER USER n8n WITH PASSWORD '${N8N_DB_PASSWORD}';
EOF
fi

# ------------------------------------------------------------
# 4. Schema + privileges
# ------------------------------------------------------------
docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres <<'EOF'
CREATE SCHEMA IF NOT EXISTS n8n;

GRANT CONNECT ON DATABASE postgres TO n8n;
GRANT ALL PRIVILEGES ON DATABASE postgres TO n8n;

GRANT ALL PRIVILEGES ON SCHEMA n8n TO n8n;

ALTER DEFAULT PRIVILEGES IN SCHEMA n8n
  GRANT ALL ON TABLES TO n8n;

ALTER DEFAULT PRIVILEGES IN SCHEMA n8n
  GRANT ALL ON SEQUENCES TO n8n;

ALTER ROLE n8n SET search_path = n8n, public;
EOF

# ------------------------------------------------------------
# 5. Ownership + extensions
# ------------------------------------------------------------
docker exec -i "$DB_CONTAINER" psql -U supabase_admin -d postgres <<'EOF'
ALTER SCHEMA n8n OWNER TO n8n;
CREATE EXTENSION IF NOT EXISTS vector;
EOF

print_line
echo "Postgres configuration applied successfully"
print_line

# ------------------------------------------------------------
# 6. Update n8n/.env
# ------------------------------------------------------------
if [ "$UPDATE_ENV" = true ]; then
  if [ -f "$N8N_ENV_FILE" ] && [ -w "$N8N_ENV_FILE" ]; then
    print_line
    echo "Updating $N8N_ENV_FILE"
    print_line

    sed -i.bak "/^DB_TYPE=/d" "$N8N_ENV_FILE"
    sed -i.bak "/^DB_POSTGRESDB_/d" "$N8N_ENV_FILE"

    cat >>"$N8N_ENV_FILE" <<ENV
DB_TYPE=postgresdb
DB_POSTGRESDB_HOST=supabase-db
DB_POSTGRESDB_PORT=5432
DB_POSTGRESDB_DATABASE=postgres
DB_POSTGRESDB_SCHEMA=n8n
DB_POSTGRESDB_USER=n8n
DB_POSTGRESDB_PASSWORD=$N8N_DB_PASSWORD
ENV

    echo "n8n/.env updated (backup saved as .env.bak)"
  else
    echo "WARNING: Cannot write to n8n/.env"
  fi
fi

# ------------------------------------------------------------
# 7. Recreate n8n container
# ------------------------------------------------------------
print_line
echo "Recreating n8n container..."
print_line

cd "$N8N_COMPOSE_DIR"
docker compose down
docker compose up -d

print_line
echo "Initialization finished successfully"
print_line