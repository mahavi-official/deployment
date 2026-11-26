#!/bin/bash
# Builds dist/site.zip for a single Azure App Service (Linux, Node).
# Ships backend SOURCE + prebuilt frontend .next. node_modules are installed
# on the server by startup.sh, so native binaries match Linux.
# Works in plain Git Bash on Windows: uses tar + Python (no rsync/zip needed).
#
# Usage:
#   FRONTEND_SRC=/e/RK/nikunja-web-frontend \
#   BACKEND_SRC=/e/RK/NikunjaWebBackend \
#   AZ_RG=Radhakundah-Production AZ_APP=radhakundah-v2 \
#   bash build-package.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BACKEND_SRC="${BACKEND_SRC:-$ROOT/NikunjaWebBackend}"
FRONTEND_SRC="${FRONTEND_SRC:-$ROOT/nikunja-web-frontend}"
AZ_RG="${AZ_RG:-Radhakundah-Production}"
AZ_APP="${AZ_APP:-radhakundah-v2}"
OUT="$HERE/dist/wwwroot"

# Never ship secrets, local DB dumps or build junk.
EXCLUDES=(
  --exclude=node_modules --exclude=.git --exclude=dist
  --exclude='.env*' --exclude=tests --exclude=coverage
  --exclude=backups --exclude='*.dump' --exclude='*.log'
)

# Find Python (python or python3).
PY="$(command -v python || command -v python3 || true)"
[ -n "$PY" ] || { echo "ERROR: Python not found."; exit 1; }
for tool in tar npm node; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: '$tool' not found."; exit 1; }
done
[ -d "$BACKEND_SRC" ]  || { echo "ERROR: backend not found at $BACKEND_SRC";  exit 1; }
[ -d "$FRONTEND_SRC" ] || { echo "ERROR: frontend not found at $FRONTEND_SRC"; exit 1; }

echo "==> Backend:  $BACKEND_SRC"
echo "==> Frontend: $FRONTEND_SRC"

echo "==> Cleaning $HERE/dist"
rm -rf "$HERE/dist"
mkdir -p "$OUT/backend" "$OUT/frontend" "$OUT/deploy/gateway"

echo "==> Staging backend source"
tar -C "$BACKEND_SRC" "${EXCLUDES[@]}" -cf - . | tar -C "$OUT/backend" -xf -

# NEXT_PUBLIC_* values are baked in at build time: put PRODUCTION URLs in
# the frontend's .env.production before running this.
echo "==> Building frontend"
(cd "$FRONTEND_SRC" && npm ci --include=dev && npm run build)

echo "==> Staging frontend source + .next (without .next/cache)"
tar -C "$FRONTEND_SRC" "${EXCLUDES[@]}" --exclude='./.next/cache' -cf - . | tar -C "$OUT/frontend" -xf -

echo "==> Copying gateway + startup script"
cp "$HERE/startup.sh" "$OUT/deploy/startup.sh"
cp "$HERE/gateway/server.js" "$OUT/deploy/gateway/server.js"
sed -i 's/\r$//' "$OUT/deploy/startup.sh" "$OUT/deploy/gateway/server.js"

# Unique per package so startup.sh reinstalls on every new deploy.
date -u +"%Y%m%d%H%M%S" > "$OUT/deploy/deploy-id"
echo "    deploy-id: $(cat "$OUT/deploy/deploy-id")"

echo "==> Safety check: looking for secret files in the package"
SECRETS="$(find "$OUT" \( -name '.env*' -o -name '*.pem' -o -name '*.key' \) -not -path '*/node_modules/*' || true)"
if [ -n "$SECRETS" ]; then
  echo "ERROR: secret-looking files found in package:"; echo "$SECRETS"
  exit 1
fi

echo "==> Zipping"
(cd "$OUT" && "$PY" -m zipfile -c "$HERE/dist/site.zip" backend frontend deploy)

echo "==> Done: $HERE/dist/site.zip ($(du -h "$HERE/dist/site.zip" | cut -f1))"
echo "    Deploy with:"
echo "      az webapp deploy --resource-group $AZ_RG --name $AZ_APP --src-path \"$HERE/dist/site.zip\" --type zip"
echo "    First boot installs dependencies and can take several minutes."
echo "    Keep WEBSITES_CONTAINER_START_TIME_LIMIT=1800 set on the web app."