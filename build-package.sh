#!/bin/bash
# Builds deploy/dist/site.zip for a single Azure App Service (Linux, Node).
# Ships backend SOURCE + prebuilt frontend .next. node_modules are installed
# on the server by startup.sh, so native binaries match Linux.
#
# Usage (Git Bash / WSL):
#   BACKEND_SRC=/e/RK/NikunjaWebBackend \
#   FRONTEND_SRC=/e/RK/nikunja-web-frontend \
#   AZ_RG=<resource-group> AZ_APP=<web-app-name> \
#   bash deploy/build-package.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BACKEND_SRC="${BACKEND_SRC:-$ROOT/NikunjaWebBackend}"
FRONTEND_SRC="${FRONTEND_SRC:-$ROOT/frontend/nikunja-web-frontend}"
AZ_RG="${AZ_RG:-<resource-group>}"
AZ_APP="${AZ_APP:-<web-app-name>}"
OUT="$HERE/dist/wwwroot"

# Never ship secrets, local DB dumps or build junk.
EXCLUDES=(
  --exclude node_modules --exclude .git --exclude dist
  --exclude '.env*' --exclude tests --exclude coverage
  --exclude backups --exclude '*.sql' --exclude '*.dump' --exclude '*.log'
)

for tool in rsync zip npm node; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: '$tool' not found. Run this in WSL (Ubuntu) or install it."; exit 1; }
done
[ -d "$BACKEND_SRC" ]  || { echo "ERROR: backend not found at $BACKEND_SRC";  exit 1; }
[ -d "$FRONTEND_SRC" ] || { echo "ERROR: frontend not found at $FRONTEND_SRC"; exit 1; }

echo "==> Backend:  $BACKEND_SRC"
echo "==> Frontend: $FRONTEND_SRC"

echo "==> Cleaning $HERE/dist"
rm -rf "$HERE/dist"
mkdir -p "$OUT/backend" "$OUT/frontend" "$OUT/deploy/gateway"

echo "==> Staging backend source"
rsync -a "${EXCLUDES[@]}" "$BACKEND_SRC/" "$OUT/backend/"

# NEXT_PUBLIC_* values are baked in at build time: put PRODUCTION URLs in
# the frontend's .env.production before running this.
echo "==> Building frontend"
(cd "$FRONTEND_SRC" && npm ci --include=dev && npm run build)

echo "==> Staging frontend source + .next (without .next/cache)"
rsync -a "${EXCLUDES[@]}" --exclude '.next/cache' "$FRONTEND_SRC/" "$OUT/frontend/"

echo "==> Copying gateway + startup script"
cp "$HERE/startup.sh" "$OUT/deploy/startup.sh"
cp "$HERE/gateway/server.js" "$OUT/deploy/gateway/server.js"
chmod +x "$OUT/deploy/startup.sh"

# Unique per package so startup.sh reinstalls on every new deploy.
date -u +"%Y%m%d%H%M%S" > "$OUT/deploy/deploy-id"
echo "    deploy-id: $(cat "$OUT/deploy/deploy-id")"

echo "==> Safety check: looking for secret files in the package"
if find "$OUT" -name '.env*' -o -name '*.pem' -o -name '*.key' | grep -q .; then
  echo "ERROR: secret-looking files found in package:"; find "$OUT" -name '.env*' -o -name '*.pem' -o -name '*.key'
  exit 1
fi

echo "==> Zipping"
(cd "$OUT" && zip -rqy "$HERE/dist/site.zip" .)

echo "==> Done: $HERE/dist/site.zip ($(du -h "$HERE/dist/site.zip" | cut -f1))"
echo "    Deploy with:"
echo "      az webapp deploy --resource-group $AZ_RG --name $AZ_APP --src-path $HERE/dist/site.zip --type zip"
echo "    First boot installs dependencies and can take several minutes."
echo "    Keep WEBSITES_CONTAINER_START_TIME_LIMIT=1800 set on the web app."