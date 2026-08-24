# Deploying both apps to a single Azure App Service — what broke and why

Record of getting the Radhakundah frontend (Next.js 15) and backend (Fastify +
Prisma) running together in **one** Azure App Service, and the ten distinct
failures hit along the way.

- **App Service:** `Radhakundah` (resource group `Radhakundah-Production`)
- **Host:** `radhakundah-b6b5f0fnh3hrf2d9.australiacentral-01.azurewebsites.net`
- **Runtime:** Linux, `NODE|24-lts`
- **Startup command:** `bash /home/site/wwwroot/deploy/startup.sh`

---

## 1. The architecture

One App Service, one hostname, three processes:

```
Browser
  |
  v
App Service ($PORT = 8080)
  |
  v
deploy/gateway/server.js        (zero-dependency node:http reverse proxy)
  |-- /api, /docs, /health, /sitemap.xml*  -->  backend  127.0.0.1:4000
  `-- everything else                      -->  frontend 127.0.0.1:3000
```

Because both apps share one origin, the browser calls `/api/v1/...`
same-origin and the gateway routes it internally — no CORS involved.

### Files

| File | Role |
|---|---|
| `deploy/gateway/server.js` | Reverse proxy. No dependencies on purpose. |
| `deploy/startup.sh` | App Service startup command. Installs, builds, launches all three processes. |
| `deploy/build-package.sh` | Builds `deploy/dist/site.zip` for zip-deploy. Ships **source only**. |
| `deploy/README.md` | Setup/config reference. |

---

## 2. Issues hit, in order

### Issue 1 — 502 Bad Gateway: backend couldn't resolve `@/server`

```
Error [ERR_MODULE_NOT_FOUND]: Cannot find package '@/server'
imported from /home/site/wwwroot/backend/dist/index.js
```

**Cause.** The source uses the `@/*` tsconfig path alias
(`tsconfig.json` → `paths`). `tsc` type-checks against that alias but does
**not** rewrite it in emitted JS — the compiled `dist/index.js` still said
`import { buildApp } from "@/server"`. Node's ESM resolver has no concept of
tsconfig paths, so it treats `@/server` as a bare package name and fails.
It had never surfaced before because `npm run dev` uses `tsx`, which *does*
resolve the alias.

**First fix (later superseded).** Added `tsc-alias` to the build:
`"build": "tsc && tsc-alias -p tsconfig.json"`.

### Issue 2 — 502 Bad Gateway: frontend couldn't resolve `../server/require-hook`

```
Error: Cannot find module '../server/require-hook'
Require stack: - /home/site/wwwroot/frontend/node_modules/.bin/next
```

**Cause.** `node_modules/.bin/next` is normally a symlink to
`../next/dist/bin/next`. It arrived on the server as a *regular file*
containing the target's contents, at the wrong depth — so its own relative
`require` resolved against `.bin/` instead of `next/dist/bin/`. (Root cause
identified in Issue 4.)

**Fix.** Invoke Next's real entry point rather than the `.bin` shim:

```bash
node node_modules/next/dist/bin/next start -H 0.0.0.0 -p 3000
```

### Issue 3 — `next build` failed: `TypeError: Invalid URL`

```
TypeError: Invalid URL
  at next.config.mjs:16:34
  input: 'radhakundah-b6b5f0fnh3hrf2d9.australiacentral-01.azurewebsites.net'
```

**Cause.** `frontend/.env` had the four URL variables set to a bare hostname
with no scheme. `next.config.mjs:20` does `new URL(cdn)`, which requires a
full URL.

**Fix.** Prefixed `https://` on `NEXT_PUBLIC_API_URL`, `API_INTERNAL_URL`,
`NEXT_PUBLIC_SITE_URL`, `NEXT_PUBLIC_CDN_URL`.

### Issue 4 — backend still failed, now on `./server`

```
Error [ERR_MODULE_NOT_FOUND]: Cannot find module
'/home/site/wwwroot/backend/dist/server'
Did you mean to import "./server.js"?
```

**Cause.** `tsc-alias` fixed the `@/*` aliases, but ~48 source files also use
plain extensionless relative imports (`from "./research.controller"`).
Node ESM requires the explicit `.js` extension; `tsc` doesn't add it.

**Fix.** Stopped fighting the compiled output and ran production the same way
dev already works — through **tsx**, which resolves both the alias and
extensionless specifiers:

```bash
node node_modules/tsx/dist/cli.mjs src/index.ts
```

### Issue 5 — `tsx` itself was broken the same way as `next`

```
Error [ERR_MODULE_NOT_FOUND]: Cannot find module
'.../node_modules/.bin/package-7qisTQEg.mjs'
imported from /home/site/wwwroot/backend/node_modules/.bin/tsx
```

**Root cause — the real one behind Issue 2 as well.** macOS `zip`
**dereferences symlinks by default**. `build-package.sh` was flattening every
`node_modules/.bin/*` symlink into a copy of its target's content at the
wrong path, breaking that target's relative imports.

**Fix.** `zip -y` stores symlinks as symlinks:

```bash
(cd "$OUT" && zip -rqy "$HERE/dist/site.zip" .)
```

Verified afterwards: `.bin/next` = 21 bytes, `.bin/tsx` = 19 bytes — the
lengths of their target paths, i.e. genuine symlinks.

### Issue 6 — esbuild built for the wrong platform

```
You installed esbuild for another platform than the one you're currently using.
Specifically the "@esbuild/darwin-arm64" package is present but this platform
needs the "@esbuild/linux-x64" package instead.
```

**Cause — the structural one.** `npm ci` was running on macOS and the
resulting `node_modules` was being shipped wholesale to Azure's Linux
container. Every package with a native binary is wrong under that scheme:
esbuild (which `tsx` depends on), Prisma's query engine, `sharp`, Next's SWC.
Patching them one at a time was never going to converge.

**Fix — changed the deployment model.** The zip now ships **source only**;
`npm ci` and `npm run build` run on the App Service itself, so installed
binaries always match the machine running them. `site.zip` went from **273 MB
to 672 KB**, which also made uploads reliable (see §4).

### Issue 7 — container exited with code 127

```
Container exited with exit code 127 during startup after 213.6s
```

**Cause.** Exit 127 = "command not found". Azure sets `NODE_ENV=production`,
which makes npm **omit devDependencies**. But the backend *runs* on `tsx` and
the frontend *builds* with `typescript`/`tailwind` — all devDependencies. The
backend's `postinstall` (`tsx scripts/bootstrap-db.ts`) then invoked a `tsx`
that was never installed → 127 → `set -e` killed the container.

**Fix.**

```bash
npm ci --include=dev --ignore-scripts && npx prisma generate
```

- `--include=dev` — we genuinely need those packages at runtime/build time.
- `--ignore-scripts` — the `postinstall` needs tsx before tsx exists, *and*
  applies DB migrations, which is a deploy concern, not a boot concern.
- Explicit `prisma generate` because `--ignore-scripts` also skips Prisma's
  own client-generation hook.

### Issue 8 — startup probe timed out at 1800s

```
Container did not respond to startup probe on port 8080 within the expected
time limit of 1800s. No listening ports were detected in the container.
```

**Cause.** `startup.sh` did all install/build work *before* starting anything
that listens. `npm ci` ×2 + `next build` on `/home` — a network-mounted
share — is slow enough to blow past even the 1800s maximum. App Service then
killed the container, and nothing ever came up.

**Fix — reordered startup.** The gateway now starts **first**, so the
platform sees a listening port within seconds; install/build happens after,
taking as long as it needs. The gateway answers `503 + Retry-After: 30` with
`"Application is starting, please retry shortly."` while upstreams are down,
distinguishing "still booting" from a genuine `502`.

Also added a **build stamp** (`sha` of both `package-lock.json` files) so
routine container restarts skip reinstall/rebuild entirely instead of
repeating several minutes of downtime.

### Issue 9 — backend exited: missing env var

```
❌ Invalid environment variables:
  SUPER_ADMIN_NAME: Required
```

`src/config/env.ts` validates the whole schema at import and calls
`process.exit(1)` on the first failure. **Fix:** set the app setting.

### Issue 10 — database had no schema

```
Could not ensure super admin: The table `public.User` does not exist
in the current database.
```

**Cause.** Migrations had previously ridden along on the backend's
`postinstall`, which `--ignore-scripts` (Issue 7) correctly disabled.

**Fix.** Explicit step in `startup.sh`, before the backend launches:

```bash
(cd "$ROOT/backend" && npx prisma migrate deploy) \
  || echo "[startup] WARNING: prisma migrate deploy failed"
```

Idempotent, so it runs every boot — that's what makes a code-only redeploy
pick up its migrations. Deliberately **non-fatal**: a briefly unreachable
database shouldn't take down the gateway and frontend too.

### Issue 11 — Google login redirected back still logged out

No server-side error — the login *succeeded*; the browser silently discarded
the session cookie.

**Cause.** `COOKIE_DOMAIN` was never set as an app setting, so
`src/config/env.ts:18` fell back to its default `.radhakundah.com`. The
backend issued `Set-Cookie: refreshToken=…; Domain=.radhakundah.com` from a
host of `radhakundah-….azurewebsites.net`. Domain mismatch → browser rejects
the cookie → `/api/v1/auth/refresh` finds no cookie → 401 → UI reverts to the
login button.

**Fix.** Set `COOKIE_DOMAIN` to the actual host, and `COOKIE_SECURE=true`
(the site is HTTPS-only).

> Note: `*.azurewebsites.net` is on the Public Suffix List, so a leading-dot
> `.azurewebsites.net` would *also* be rejected. It must be the exact
> hostname.

---

## 3. App settings changed

| Setting | Before | After | Reason |
|---|---|---|---|
| `WEBSITES_CONTAINER_START_TIME_LIMIT` | unset (230s) | `1800` | Issue 8 |
| `SUPER_ADMIN_NAME` | unset | `Nikunja` | Issue 9 |
| `COOKIE_DOMAIN` | unset → `.radhakundah.com` | `radhakundah-b6b5f0fnh3hrf2d9.australiacentral-01.azurewebsites.net` | Issue 11 |
| `COOKIE_SECURE` | `false` | `true` | HTTPS-only site |

---

## 4. Deployment mechanics

`az webapp deploy` repeatedly returned **504 GatewayTimeout** while the
server-side deployment carried on succeeding — the CLI just stopped waiting.
One run hung indefinitely without ever registering server-side.

More reliable, and what the current flow uses:

```bash
curl -u "$USER:$PASS" -X POST -T deploy/dist/site.zip \
  "https://<app>.scm.<region>.azurewebsites.net/api/zipdeploy?isAsync=true" \
  -H "Content-Type: application/octet-stream"
```

Returns `202 Accepted` with an `SCM-DEPLOYMENT-ID` header; poll
`/api/deployments/<id>` until `complete: true` (`status: 4` = success).

Credentials: `az webapp deployment list-publishing-credentials -g <rg> -n <app>`

> `Content-Type: application/zip` returns **400**; use
> `application/octet-stream`.

### Full redeploy

```bash
deploy/build-package.sh          # -> deploy/dist/site.zip (~672 KB)
# upload via the curl above, poll until complete
az webapp restart -g Radhakundah-Production -n Radhakundah
```

First boot after a dependency change runs the full install+build (several
minutes, serving 503 meanwhile). Subsequent restarts hit the build stamp and
come up in seconds.

---

## 5. Where to look when it breaks

Via Kudu VFS: `https://<app>.scm.<region>.azurewebsites.net/api/vfs/<path>`

| Path | Contents |
|---|---|
| `/home/LogFiles/StartupLogs/.sources/<date>_<instance>_containerStream.log` | **Most useful.** Real stdout/stderr of your processes — every `MODULE_NOT_FOUND`, the esbuild mismatch, the env-validation failure. |
| `/home/LogFiles/<date>_<instance>_docker.log` | Platform events — exit codes, probe timeouts, container lifecycle. |
| `/home/LogFiles/StartupLogs/<date>_<instance>_{success,failure}.log` | Merged status + stream per start attempt. |

Live tail: `az webapp log tail -g Radhakundah-Production -n Radhakundah`

Backend-only (it logs pino JSON): pipe through `grep '"level"'`.

**Caveat learned the hard way:** Issue 11 produced *no* log output at all.
Cookie rejections are only visible in the browser — DevTools → Network →
the callback response → Set-Cookie, which flags the domain mismatch.

---

## 6. Follow-ups

**Security — needs attention.** `NikunjaWebBackend/.env.example` currently
contains real production credentials (database password, Google OAuth
secret). `.env.example` is meant to be a committed placeholder file. Those
credentials should be treated as compromised and rotated, and the file
reverted to placeholders.

**Moving to the real domain** (`radhakundah.com`) means updating every
host-coupled setting together: `SITE_URL`, `API_URL`, `CORS_ORIGINS`,
`COOKIE_DOMAIN` (→ `.radhakundah.com`), `GOOGLE_CALLBACK_URL`,
`NEXT_PUBLIC_API_URL`, `NEXT_PUBLIC_SITE_URL`. The frontend bakes
`NEXT_PUBLIC_*` in at build time, so it needs a rebuild — bump the build
stamp or delete `/home/site/wwwroot/.build-stamp` to force one.

**Google Cloud Console** must list the callback under Authorized redirect
URIs or the callback fails with `redirect_uri_mismatch`.

**Worth reconsidering later:**

- Building on the server means every dependency change costs minutes of
  degraded service. Building in a **Linux container in CI** (`node:24-bookworm-slim`)
  and shipping the built artifact gets correct native binaries *and* fast
  boots. That was the alternative to the current approach.
- The backend runs through `tsx` (a dev-oriented runner) in production. The
  cleaner long-term fix is adding `.js` extensions to relative imports so
  plain `node dist/index.js` works.
- `deploy/dist/` should be gitignored.
