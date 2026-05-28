const express = require("express");
const http = require("http");
const https = require("https");
const url = require("url");

const app = express();
const PORT = process.env.PORT || 8080;

// CORS — allow our web app
app.use((req, res, next) => {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "GET, OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "Range, Accept, Content-Type");
  res.setHeader(
    "Access-Control-Expose-Headers",
    "Content-Length, Content-Range, Content-Type, Accept-Ranges",
  );
  if (req.method === "OPTIONS") {
    res.status(204).end();
    return;
  }
  next();
});

// Stream proxy endpoint
app.get("/proxy", (req, res) => {
  const targetUrl = req.query.url;
  if (!targetUrl) {
    res.status(400).json({ error: "Missing ?url= parameter" });
    return;
  }

  let parsed;
  try {
    parsed = new url.URL(targetUrl);
  } catch (_) {
    res.status(400).json({ error: "Invalid URL" });
    return;
  }

  if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
    res.status(400).json({ error: "Only http/https" });
    return;
  }

  const client = parsed.protocol === "https:" ? https : http;

  const options = {
    hostname: parsed.hostname,
    port: parsed.port || (parsed.protocol === "https:" ? 443 : 80),
    path: parsed.pathname + parsed.search,
    method: "GET",
    headers: {
      "User-Agent": "LunarIPTV-StreamProxy/1.0",
      Accept: "*/*",
      // Forward Range header for seeking support
      ...(req.headers["range"] ? { Range: req.headers["range"] } : {}),
    },
    timeout: 15000,
  };

  const proxyReq = client.request(options, (proxyRes) => {
    const status = proxyRes.statusCode || 200;
    res.status(status);

    // Forward critical headers for HLS/TS streaming
    const forwardHeaders = [
      "content-type",
      "content-length",
      "content-range",
      "accept-ranges",
      "cache-control",
      "transfer-encoding",
    ];
    for (const h of forwardHeaders) {
      if (proxyRes.headers[h]) res.setHeader(h, proxyRes.headers[h]);
    }

    proxyRes.pipe(res, { end: true });
  });

  proxyReq.on("timeout", () => {
    proxyReq.destroy();
    if (!res.headersSent) res.status(504).json({ error: "Timeout" });
  });

  proxyReq.on("error", (err) => {
    if (!res.headersSent) res.status(502).json({ error: err.message });
  });

  req.on("close", () => proxyReq.destroy());
  proxyReq.end();
});

// Health check
app.get("/health", (_, res) => res.json({ status: "ok" }));

app.listen(PORT, () => console.log(`Stream proxy running on :${PORT}`));
