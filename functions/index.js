// cd functions; npm run lint -- --fix; cd ..
const {onRequest} = require("firebase-functions/v2/https");
const http = require("http");
const https = require("https");
const urlModule = require("url");

exports.iptvProxy = onRequest(
    {timeoutSeconds: 60, memory: "256MiB", cors: false},
    (req, res) => {
      res.set("Access-Control-Allow-Origin", "*");
      res.set("Access-Control-Allow-Methods", "GET, OPTIONS");
      res.set("Access-Control-Allow-Headers", "Accept, Content-Type, X-Requested-With");
      res.set("Access-Control-Max-Age", "86400");

      if (req.method === "OPTIONS") {
        res.status(204).send("");
        return;
      }
      if (req.method !== "GET") {
        res.status(405).json({error: "Method not allowed"});
        return;
      }

      const targetUrl = req.query.url;
      if (!targetUrl) {
        res.status(400).json({error: "Missing ?url= parameter"});
        return;
      }

      let parsed;
      try {
        parsed = new urlModule.URL(targetUrl);
      } catch (_) {
        res.status(400).json({error: "Invalid URL"});
        return;
      }

      if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
        res.status(400).json({error: "Only http/https allowed"});
        return;
      }

      const client = parsed.protocol === "https:" ? https : http;
      const options = {
        hostname: parsed.hostname,
        port: parsed.port || (parsed.protocol === "https:" ? 443 : 80),
        path: parsed.pathname + parsed.search,
        method: "GET",
        headers: {
          "Accept": "application/json",
          "User-Agent": "LunarIPTV-Proxy/1.0",
        },
        timeout: 30000,
      };

      const proxyReq = client.request(options, (proxyRes) => {
        res.status(proxyRes.statusCode || 200);
        res.set("Content-Type", proxyRes.headers["content-type"] || "application/json");
        proxyRes.pipe(res);
      });

      proxyReq.on("timeout", () => {
        proxyReq.destroy();
        if (!res.headersSent) res.status(504).json({error: "Upstream timeout"});
      });

      proxyReq.on("error", (err) => {
        if (!res.headersSent) res.status(502).json({error: err.message});
      });

      proxyReq.end();
    },
);
