// cd functions; npm run lint -- --fix; cd ..
const {onRequest} = require("firebase-functions/v2/https");
const http = require("http");
const https = require("https");
const dns = require("dns");
const net = require("net");
const {URL} = require("url");

// ─────────────────────────────────────────────────────────────────────────────
// iptvProxy: the original JSON-only API proxy (kept for older web builds).
// ─────────────────────────────────────────────────────────────────────────────
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
        parsed = new URL(targetUrl);
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

// ─────────────────────────────────────────────────────────────────────────────
// mediaProxy: everything the web app loads from IPTV servers.
//
// The web app runs on HTTPS, so the browser blocks plain-HTTP servers
// (mixed content) and any server without CORS headers. This relays the
// request over HTTPS and adds CORS:
//   • Xtream API (player_api.php), M3U playlists, XMLTV guides
//   • Live / VOD streams, with Range for seeking
//   • HLS playlists, rewritten so every segment / key / sub-playlist goes
//     through the proxy too (relative links resolve against the real server)
//   • Redirects are followed here (Xtream servers often bounce streams to a
//     load balancer), so the browser only ever talks to this proxy.
//
// Guards: only requests from the Lunar web app (Origin / Referer), and never
// private / internal addresses (no SSRF into Google's network).
// ─────────────────────────────────────────────────────────────────────────────

const ALLOWED_SITES = [
  "lunar-iptv-app.web.app",
  "lunar-iptv-app.firebaseapp.com",
  "lunar-iptv.web.app",
  "localhost",
  "127.0.0.1",
];

const UPSTREAM_UA = "VLC/3.0.20 LibVLC/3.0.20";
const MAX_REDIRECTS = 5;
const MAX_PLAYLIST_BYTES = 8 * 1024 * 1024;

const hostOf = (value) => {
  if (!value) return null;
  try {
    return new URL(value).hostname;
  } catch (_) {
    return null;
  }
};

// True when the request comes from the Lunar web app.
const allowedCaller = (req) => {
  const host = hostOf(req.get("origin")) || hostOf(req.get("referer"));
  return host !== null && ALLOWED_SITES.indexOf(host) !== -1;
};

// Private, loopback, link-local, metadata and other non-public ranges.
const isPrivateIp = (ip) => {
  if (net.isIPv4(ip)) {
    const p = ip.split(".").map(Number);
    return p[0] === 10 || p[0] === 127 || p[0] === 0 ||
      (p[0] === 169 && p[1] === 254) ||
      (p[0] === 172 && p[1] >= 16 && p[1] <= 31) ||
      (p[0] === 192 && p[1] === 168) ||
      (p[0] === 100 && p[1] >= 64 && p[1] <= 127) ||
      p[0] >= 224;
  }
  const v6 = ip.toLowerCase();
  if (v6.startsWith("::ffff:")) return isPrivateIp(v6.substring(7));
  return v6 === "::1" || v6 === "::" || v6.startsWith("fc") ||
    v6.startsWith("fd") || v6.startsWith("fe8") || v6.startsWith("fe9") ||
    v6.startsWith("fea") || v6.startsWith("feb");
};

// DNS lookup that refuses non-public addresses (checked at connect time).
const safeLookup = (hostname, options, callback) => {
  dns.lookup(hostname, options, (err, address, family) => {
    if (err) return callback(err);
    const list = Array.isArray(address) ? address : [{address, family}];
    for (const a of list) {
      if (isPrivateIp(a.address)) {
        return callback(new Error("Blocked address"));
      }
    }
    return callback(null, address, family);
  });
};

const isHlsUrl = (u) => /\.m3u8?($|\?)/i.test(u.pathname + u.search) ||
  u.pathname.toLowerCase().indexOf("m3u8") !== -1;

// Opens [target], following redirects. Resolves with {res, url} where url
// is the final address (the base for relative links in HLS playlists).
const fetchUpstream = (target, req, hops) => new Promise((resolve, reject) => {
  // Literal IPs skip the DNS lookup, so check them here.
  const literal = target.hostname.replace(/^\[|\]$/g, "");
  if (net.isIP(literal) && isPrivateIp(literal)) {
    reject(new Error("Blocked address"));
    return;
  }
  const client = target.protocol === "https:" ? https : http;
  const headers = {
    "User-Agent": UPSTREAM_UA,
    "Accept": "*/*",
    "Accept-Encoding": "identity",
  };
  if (req.headers["range"]) headers["Range"] = req.headers["range"];
  if (req.headers["if-range"]) headers["If-Range"] = req.headers["if-range"];

  const upstream = client.request(target, {
    method: req.method === "HEAD" ? "HEAD" : "GET",
    headers,
    lookup: safeLookup,
    timeout: 30000,
  }, (res) => {
    const code = res.statusCode || 0;
    if (code >= 300 && code < 400 && res.headers.location) {
      res.resume();
      if (hops >= MAX_REDIRECTS) {
        reject(new Error("Too many redirects"));
        return;
      }
      let next;
      try {
        next = new URL(res.headers.location, target);
      } catch (_) {
        reject(new Error("Bad redirect"));
        return;
      }
      if (next.protocol !== "http:" && next.protocol !== "https:") {
        reject(new Error("Bad redirect"));
        return;
      }
      fetchUpstream(next, req, hops + 1).then(resolve, reject);
      return;
    }
    resolve({res, url: target});
  });
  upstream.on("timeout", () => upstream.destroy(new Error("Upstream timeout")));
  upstream.on("error", reject);
  req.on("close", () => upstream.destroy());
  upstream.end();
});

// Points every URI in an HLS playlist back at this proxy.
const rewritePlaylist = (text, base) => {
  const proxied = (ref) => {
    try {
      return "?url=" + encodeURIComponent(new URL(ref.trim(), base).toString());
    } catch (_) {
      return ref;
    }
  };
  return text.split(/\r?\n/).map((line) => {
    const t = line.trim();
    if (t === "") return line;
    if (t.charAt(0) !== "#") return proxied(t);
    return line.replace(/URI="([^"]+)"/g, (_, ref) => `URI="${proxied(ref)}"`);
  }).join("\n");
};

// Standard media type for HLS segment / init files, or null to keep.
const standardType = (path, type) => {
  const p = path.toLowerCase();
  const generic = type === "" ||
    /octet-stream|text\/plain|video\/m2ts|binary/i.test(type);
  if (/\.ts$/.test(p) && !/mp2t/i.test(type)) return "video/mp2t";
  if (!generic) return null;
  if (/\.(m4s|mp4|m4v)$/.test(p)) return "video/mp4";
  if (/\.aac$/.test(p)) return "audio/aac";
  if (/\.(vtt|webvtt)$/.test(p)) return "text/vtt";
  return null;
};

const setCors = (req, res) => {
  const origin = req.get("origin");
  res.set("Access-Control-Allow-Origin", origin || "*");
  res.set("Vary", "Origin");
  res.set("Access-Control-Allow-Methods", "GET, HEAD, OPTIONS");
  res.set("Access-Control-Allow-Headers", "Range, If-Range, Accept, Content-Type");
  res.set("Access-Control-Expose-Headers",
      "Content-Length, Content-Range, Content-Type, Accept-Ranges");
  res.set("Access-Control-Max-Age", "86400");
};

exports.mediaProxy = onRequest(
    {
      region: "us-central1",
      timeoutSeconds: 3600,
      memory: "512MiB",
      concurrency: 80,
      maxInstances: 20,
      cors: false,
    },
    async (req, res) => {
      setCors(req, res);
      if (req.method === "OPTIONS") {
        res.status(204).end();
        return;
      }
      if (req.method !== "GET" && req.method !== "HEAD") {
        res.status(405).json({error: "Method not allowed"});
        return;
      }
      if (!allowedCaller(req)) {
        res.status(403).json({error: "Forbidden"});
        return;
      }

      let target;
      try {
        target = new URL(String(req.query.url || ""));
      } catch (_) {
        res.status(400).json({error: "Invalid url"});
        return;
      }
      if (target.protocol !== "http:" && target.protocol !== "https:") {
        res.status(400).json({error: "Only http/https"});
        return;
      }

      let upstream;
      try {
        upstream = await fetchUpstream(target, req, 0);
      } catch (err) {
        if (!res.headersSent) res.status(502).json({error: err.message});
        return;
      }
      const up = upstream.res;
      const status = up.statusCode || 502;
      const type = String(up.headers["content-type"] || "");

      const looksHls = /mpegurl/i.test(type) ||
        (isHlsUrl(upstream.url) && !/video|audio|octet/i.test(type));

      if (looksHls && status < 300 && req.method !== "HEAD") {
        // Buffer the (small) playlist and rewrite its links.
        const chunks = [];
        let size = 0;
        up.on("data", (c) => {
          size += c.length;
          if (size > MAX_PLAYLIST_BYTES) {
            up.destroy();
            if (!res.headersSent) res.status(502).json({error: "Playlist too large"});
            return;
          }
          chunks.push(c);
        });
        up.on("end", () => {
          if (res.headersSent) return;
          const text = Buffer.concat(chunks).toString("utf8");
          // Only HLS media playlists are rewritten (#EXT-X- tags); plain
          // M3U channel lists pass through untouched.
          const hls = text.indexOf("#EXT-X-") !== -1;
          const body = hls ? rewritePlaylist(text, upstream.url) : text;
          res.status(status);
          res.set("Content-Type", hls || !type ?
            "application/vnd.apple.mpegurl" :
            type);
          res.set("Cache-Control", "no-store");
          res.send(body);
        });
        up.on("error", (err) => {
          if (!res.headersSent) res.status(502).json({error: err.message});
        });
        return;
      }

      res.status(status);
      // No Content-Length: Cloud Run (which runs this function) rejects
      // any response over 32 MiB that declares its size up front (movies
      // failed with 500). Without it the body streams in chunks, with no
      // size limit; Content-Range still tells the player the total size,
      // so seeking keeps working.
      for (const h of [
        "content-type", "content-range", "accept-ranges",
        "last-modified", "etag",
      ]) {
        if (up.headers[h]) res.set(h, up.headers[h]);
      }
      // Chrome's built-in HLS player goes by Content-Type: servers that
      // label segments "video/m2ts", "text/plain" or "octet-stream" made
      // some channels fail. Use the standard type for known extensions.
      const fixed = standardType(upstream.url.pathname, type);
      if (fixed) res.set("Content-Type", fixed);
      // Images can be cached by the browser; everything else is live data.
      res.set("Cache-Control", /^image\//i.test(type) ?
        "public, max-age=604800" :
        "no-store");
      if (req.method === "HEAD") {
        up.resume();
        res.end();
        return;
      }
      up.pipe(res);
      up.on("error", () => res.end());
    },
);
