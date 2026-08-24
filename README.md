# Manual single-App-Service deployment

Runs both apps (Fastify backend + Next.js frontend) inside **one** Azure App
Service on **one** hostname:

```
Browser
  |
  v
App Service ($PORT, e.g. 8080)
  |
  v
deploy/gateway/server.js  (no deps, plain node:http proxy)
  |-- /api, /docs, /health, /sitemap.xml*  -->  backend  (127.0.0.1:4000)
  `-- everything else                      -->  frontend (127.0.0.1:3000)
```

`deploy/startup.sh` starts all three processes; it's the App Service
"Startup Command".

## 1. Create the App Service (one-time, if it doesn't exist yet)

```bash
az login
az group create -n rg-radhakundah -l centralindia

az appservice plan create \
  -g rg-radhakundah -n asp-radhakundah \
  --is-linux --sku B1

az webapp create \
  -g rg-radhakundah -p asp-radhakundah -n <app-name> \
  --runtime "NODE:20-lts"
```

Turn off Oryx's own build (we ship pre-built `node_modules`/`dist`/`.next`,
and Oryx doesn't understand this two-app folder layout):

```bash
az webapp config appsettings set -g rg-radhakundah -n <app-name> \
  --settings SCM_DO_BUILD_DURING_DEPLOYMENT=false WEBSITES_PORT=8080
```

Set the startup command:

```bash
az webapp config set -g rg-radhakundah -n <app-name> \
  --startup-file "bash /home/site/wwwroot/deploy/startup.sh"
```

(Portal equivalent: **Configuration > General settings > Startup Command**.)

## 2. App settings (environment variables)

Set these once via `az webapp config appsettings set ... --settings KEY=value`
or in **Configuration > Application settings**. Because both apps share one
hostname, the browser-facing and internal API URLs both point at the app
itself:

| Key | Value |
|---|---|
| `NODE_ENV` | `production` |
| `API_URL` | `https://<app-name>.azurewebsites.net` |
| `SITE_URL` | `https://<app-name>.azurewebsites.net` |
| `NEXT_PUBLIC_API_URL` | `https://<app-name>.azurewebsites.net` |
| `NEXT_PUBLIC_SITE_URL` | `https://<app-name>.azurewebsites.net` |
| `API_INTERNAL_URL` | `http://127.0.0.1:4000` |
| `CORS_ORIGINS` | `https://<app-name>.azurewebsites.net` |
| `COOKIE_DOMAIN` | `<app-name>.azurewebsites.net` |
| `COOKIE_SECURE` | `true` |
| `DATABASE_URL` | your Postgres connection string |
| `JWT_ACCESS_SECRET` | 32+ char secret |
| `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` | from Google Cloud console |
| `GOOGLE_CALLBACK_URL` | `https://<app-name>.azurewebsites.net/api/v1/auth/google/callback` |
| `SUPER_ADMIN_EMAIL` / `SUPER_ADMIN_NAME` | your admin account |
| `SMTP_HOST` / `SMTP_PORT` / `SMTP_USER` / `SMTP_PASS` / `MAIL_FROM` / `CONTACT_NOTIFY_TO` | mail settings |
| `AZURE_STORAGE_ACCOUNT_NAME` / `AZURE_STORAGE_ACCOUNT_KEY` | storage account |
| `AZURE_STORAGE_CONTAINER_PUBLIC` / `_PRIVATE` / `_BACKUP` | container names |
| `AZURE_BLOB_PUBLIC_BASE_URL` | `https://<storage-account>.blob.core.windows.net/<public-container>` |
| `NEXT_PUBLIC_CDN_URL` | same as above, or a CDN in front of it |
| `RECAPTCHA_SECRET` | optional |

Do **not** set `PORT` yourself — Azure injects it, and `startup.sh` reads it
for the gateway only (backend/frontend get fixed internal ports 4000/3000).

## 3. Build + package

From the repo root:

```bash
deploy/build-package.sh
```

This runs `npm ci && npm run build` in both apps, copies the built output
(`dist/`, `.next/`, `node_modules/`, etc.) into `deploy/dist/wwwroot/`
alongside `deploy/`, and zips it to `deploy/dist/site.zip`.

## 4. Run database migrations (first deploy, and after schema changes)

```bash
cd NikunjaWebBackend
DATABASE_URL="<production connection string>" npx prisma migrate deploy
```

## 5. Deploy

```bash
az webapp deploy \
  --resource-group rg-radhakundah --name <app-name> \
  --src-path deploy/dist/site.zip --type zip
```

(Portal equivalent: **Deployment Center > ... > Zip Push Deploy**, or drag
the zip onto `https://<app-name>.scm.azurewebsites.net/ZipDeployUI`.)

Tail logs to confirm both processes came up:

```bash
az webapp log tail -g rg-radhakundah -n <app-name>
```

You should see `[bootstrap]`/Fastify log lines, `Next.js ... ready`, and
`[gateway] listening on 8080`.

## Notes

- Redeploy after any code change by re-running `deploy/build-package.sh`
  then step 5 — nothing here watches for changes automatically.
- This is the "manual for now" path. If it moves to CI later, the same
  `deploy/` folder can be zipped by a pipeline instead of by hand.
