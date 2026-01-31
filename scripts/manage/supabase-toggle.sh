#!/usr/bin/env bash
set -e

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SUPABASE_DIR="$PROJECT_ROOT/supabase"

cd "$SUPABASE_DIR"

echo "----------------------------------------"
echo "Supabase mode switcher"
echo "Project dir: $SUPABASE_DIR"
echo "----------------------------------------"
echo "1) DB only (Postgres only)"
echo "2) FULL (all Supabase services)"
echo
read -rp "Choose mode [1/2]: " MODE

case "$MODE" in
  1)
    echo
    echo ">>> Switching to DB-only mode"
    echo "Stopping all Supabase services except Postgres..."

    docker compose stop \
      studio auth rest realtime storage meta functions kong vector imgproxy supavisor || true

    echo "----------------------------------------"
    echo "Running containers:"
    docker ps --format '{{.Names}}' | grep supabase || echo "(none)"
    echo "----------------------------------------"
    echo "Done. Only Postgres should be running."
    ;;

  2)
    echo
    echo ">>> Switching to FULL Supabase mode"
    echo "Starting all Supabase services..."

    docker compose up -d

    echo "----------------------------------------"
    echo "Running containers:"
    docker ps --format '{{.Names}}' | grep supabase || echo "(none)"
    echo "----------------------------------------"
    echo "Done. Full Supabase stack is running."
    ;;

  *)
    echo "Invalid option"
    exit 1
    ;;
esac