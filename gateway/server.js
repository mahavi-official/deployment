/**
 * Single-process reverse proxy so one Azure App Service can serve both apps
 * on one public hostname: /api, /docs, /health -> backend, everything else
 * -> the Next.js frontend. Zero dependencies on purpose (no npm install
 * step needed for the gateway itself during a manual deploy).
 */
const http = require("http");

const PORT = process.env.PORT || 8080;
const BACKEND_PORT = process.env.BACKEND_PORT || 4000;
const FRONTEND_PORT = process.env.FRONTEND_PORT || 3000;
const TARGET_HOST = "127.0.0.1";

const BACKEND_PREFIXES = ["/api", "/docs", "/health", "/sitemap.xml", "/sitemaps"];

function isBackendPath(pathname) {
  return BACKEND_PREFIXES.some((p) => pathname === p || pathname.startsWith(p + "/"));
}

function targetPortFor(pathname) {
  return isBackendPath(pathname) ? BACKEND_PORT : FRONTEND_PORT;
}

function proxy(req, res, port) {
  const proxyReq = http.request(
    {
      hostname: TARGET_HOST,
      port,
      path: req.url,
      method: req.method,
      headers: { ...req.headers, host: `${TARGET_HOST}:${port}` },
    },
    (proxyRes) => {
      res.writeHead(proxyRes.statusCode, proxyRes.headers);
      proxyRes.pipe(res);
    }
  );

  proxyReq.on("error", (err) => {
    console.error(`[gateway] upstream error ${TARGET_HOST}:${port}${req.url} - ${err.message}`);
    // The gateway deliberately starts before the apps do (see startup.sh), so
    // a refused connection usually means "still installing/building", not a
    // crash. 503 + Retry-After says that honestly; browsers and probes treat
    // it as transient rather than as a broken upstream.
    const starting = err.code === "ECONNREFUSED";
    if (!res.headersSent) {
      res.writeHead(starting ? 503 : 502, {
        "Content-Type": "text/plain",
        ...(starting ? { "Retry-After": "30" } : {}),
      });
    }
    res.end(starting ? "Application is starting, please retry shortly.\n" : "Bad gateway\n");
  });

  req.pipe(proxyReq);
}

const server = http.createServer((req, res) => {
  const pathname = req.url.split("?")[0];
  proxy(req, res, targetPortFor(pathname));
});

// Upgrade support (websockets), forwarded to whichever app owns the path.
server.on("upgrade", (req, socket, head) => {
  const pathname = req.url.split("?")[0];
  const port = targetPortFor(pathname);

  const upgradeReq = http.request({
    hostname: TARGET_HOST,
    port,
    path: req.url,
    method: req.method,
    headers: req.headers,
  });

  upgradeReq.on("upgrade", (proxyRes, proxySocket, proxyHead) => {
    const headerLines = Object.entries(proxyRes.headers)
      .map(([k, v]) => `${k}: ${v}`)
      .join("\r\n");
    socket.write(`HTTP/1.1 101 Switching Protocols\r\n${headerLines}\r\n\r\n`);
    if (proxyHead && proxyHead.length) proxySocket.write(proxyHead);
    proxySocket.pipe(socket);
    socket.pipe(proxySocket);
  });

  upgradeReq.on("error", () => socket.destroy());
  upgradeReq.end();
});

server.listen(PORT, () => {
  console.log(`[gateway] listening on ${PORT}`);
  console.log(`[gateway]   ${BACKEND_PREFIXES.join(", ")} -> backend (${TARGET_HOST}:${BACKEND_PORT})`);
  console.log(`[gateway]   everything else -> frontend (${TARGET_HOST}:${FRONTEND_PORT})`);
});
