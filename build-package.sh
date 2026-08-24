#!/bin/bash
# Assembles a wwwroot/ folder + zip containing SOURCE ONLY for both apps
# (no node_modules/.next/dist) plus deploy/, ready for a manual zip-deploy
# to a single Azure App Service (Linux Node runtime).
#
# Why source-only: `npm ci` fetches native binaries (esbuild for tsx,
# Prisma's query engine, sharp, Next's SWC) matching whatever machine runs
# the install. Installing on a developer's Mac and shipping that
# node_modules to Azure's Linux container breaks every one of those. So
# `deploy/startup.sh` runs `npm ci`/`npm run build` itself, on the actual
# Linux App Service container, the first time it starts after each deploy --
# see startup.sh for details.
#
# Usage: deploy/build-package.sh
# Output: deploy/dist/wwwroot/ (unzipped) and deploy/dist/site.zip
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BACKEND_SRC="$ROOT/NikunjaWebBackend"
FRONTEND_SRC="$ROOT/frontend/nikunja-web-frontend"
OUT="$HERE/dist/wwwroot"

echo "==> Cleaning $HERE/dist"
rm -rf "$HERE/dist"
mkdir -p "$OUT/backend" "$OUT/frontend" "$OUT/deploy/gateway"

echo "==> Staging backend source (excluding node_modules/dist/.env)"
rsync -a \
  --exclude node_modules --exclude dist --exclude .git --exclude .env --exclude tests \
  "$BACKEND_SRC/" "$OUT/backend/"
  

# Build the frontend here rather than on the server. `next build` is the
# slowest part of container boot, and its output (.next) is plain JS -- it
# ships across platforms fine. Only node_modules can't cross platforms
# (native binaries), and that is still installed server-side by startup.sh.
# NEXT_PUBLIC_* are baked in at build time, so frontend/.env must hold the
# production URLs when this runs.
echo "==> Building frontend"
(cd "$FRONTEND_SRC" && npm ci --include=dev && npm run build)

# .next/cache is webpack's incremental-build cache -- large, and unused at
# runtime. Excluding it keeps the upload small.
echo "==> Staging frontend source + build output (excluding node_modules/.next/cache/.env)"
rsync -a \
  --exclude node_modules --exclude .git --exclude .env --exclude '.next/cache' \
  "$FRONTEND_SRC/" "$OUT/frontend/"

echo "==> Copying gateway + startup script"
cp "$HERE/startup.sh" "$OUT/deploy/startup.sh"
cp "$HERE/gateway/server.js" "$OUT/deploy/gateway/server.js"
chmod +x "$OUT/deploy/startup.sh"

# Unique per package. startup.sh folds this into its build stamp, so every
# deploy rebuilds even when the lockfiles are untouched (source-only changes
# would otherwise reuse a stale .next), while a plain container restart of an
# already-built deploy still skips the install/build.
date -u +"%Y%m%d%H%M%S" > "$OUT/deploy/deploy-id"
echo "    deploy-id: $(cat "$OUT/deploy/deploy-id")"

echo "==> Zipping"
(cd "$OUT" && zip -rqy "$HERE/dist/site.zip" .)

echo "==> Done: $HERE/dist/site.zip ($(du -h "$HERE/dist/site.zip" | cut -f1))"
echo "    Deploy with:"
echo "      az webapp deploy --resource-group Radhakundah-Production --name Radhakundah --src-path $HERE/dist/site.zip --type zip"
echo ""
echo "    First boot after deploy installs + builds on the server (npm ci"
echo "    x2, next build) before the site responds -- can take a few"
echo "    minutes. Make sure WEBSITES_CONTAINER_START_TIME_LIMIT is raised"
echo "    (see deploy/README.md) so Azure doesn't kill it as unhealthy."
