const { defineConfig } = require("vite");
const react = require("@vitejs/plugin-react-swc");
const path = require("path");

const ALLOWED_IPS_URL =
  "https://api.jsonstorage.net/v1/json/21445b0b-7d33-4a73-8fc8-7f4af1cbc783/ca0c59b3-40d3-45db-88aa-9d80a1ee8504";
const WHOIS_BASE = "https://www.whois.com/whois/";
const IPIFY_URL = "https://api.ipify.org?format=json";
const IPIFY64_URL = "https://api64.ipify.org?format=json";

function extractWhoisText(html) {
  if (!html || typeof html !== "string") return "";
  const block =
    html.match(/<div[^>]*class="[^"]*whois-data[^"]*"[^>]*>([\s\S]*?)<\/div>/i) ||
    html.match(/<pre[^>]*>([\s\S]*?)<\/pre>/i) ||
    html.match(/<div[^>]*id="[^"]*registryData[^"]*"[^>]*>([\s\S]*?)<\/div>/i);
  const raw = block ? block[1] : html;
  return raw
    .replace(/<script[\s\S]*?<\/script>/gi, " ")
    .replace(/<style[\s\S]*?<\/style>/gi, " ")
    .replace(/<[^>]+>/g, " ")
    .replace(/&nbsp;/g, " ")
    .replace(/&amp;/g, "&")
    .replace(/\s+/g, " ")
    .trim();
}

function apiProxyPlugin() {
  const attach = (server) => {
    server.middlewares.use("/api/client-ip", async (_req, res) => {
      const sources = [IPIFY_URL, IPIFY64_URL];
      let lastError = null;
      for (const url of sources) {
        try {
          const upstream = await fetch(url, {
            method: "GET",
            headers: { Accept: "application/json" },
          });
          const text = await upstream.text();
          if (!upstream.ok) throw new Error("status " + upstream.status + " " + text);
          res.statusCode = 200;
          res.setHeader("Content-Type", "application/json; charset=utf-8");
          res.setHeader("Cache-Control", "no-store");
          res.end(text);
          return;
        } catch (e) {
          lastError = e;
        }
      }
      res.statusCode = 502;
      res.setHeader("Content-Type", "application/json; charset=utf-8");
      res.end(
        JSON.stringify({
          error: "ip_detect_failed",
          message: lastError instanceof Error ? lastError.message : String(lastError),
        }),
      );
    });

    server.middlewares.use("/api/allowed-ips", async (_req, res) => {
      try {
        const upstream = await fetch(ALLOWED_IPS_URL, {
          method: "GET",
          headers: {
            Accept: "application/json",
            "Cache-Control": "no-cache",
            Pragma: "no-cache",
          },
        });
        const text = await upstream.text();
        res.statusCode = upstream.status;
        res.setHeader("Content-Type", "application/json; charset=utf-8");
        res.setHeader("Cache-Control", "no-store");
        res.end(text);
      } catch (e) {
        res.statusCode = 502;
        res.setHeader("Content-Type", "application/json; charset=utf-8");
        res.end(
          JSON.stringify({
            error: "upstream_failed",
            message: e instanceof Error ? e.message : String(e),
          }),
        );
      }
    });

    server.middlewares.use("/api/whois/", async (req, res) => {
      try {
        const ip = decodeURIComponent(
          (req.url || "").replace(/^\//, "").split("?")[0] || "",
        );
        if (!ip) {
          res.statusCode = 400;
          res.setHeader("Content-Type", "application/json; charset=utf-8");
          res.end(JSON.stringify({ ok: false, error: "missing_ip" }));
          return;
        }

        const whoisUrl = WHOIS_BASE + encodeURIComponent(ip);
        const upstream = await fetch(whoisUrl, {
          method: "GET",
          headers: {
            Accept: "text/html,application/xhtml+xml",
            "User-Agent":
              "Mozilla/5.0 (compatible; ArnApexWhois/1.0; +https://localhost)",
          },
        });
        const html = await upstream.text();
        const text = extractWhoisText(html);

        res.statusCode = 200;
        res.setHeader("Content-Type", "application/json; charset=utf-8");
        res.setHeader("Cache-Control", "no-store");
        res.end(
          JSON.stringify({
            ok: upstream.ok,
            status: upstream.status,
            url: whoisUrl,
            text: text.slice(0, 4000),
          }),
        );
      } catch (e) {
        res.statusCode = 502;
        res.setHeader("Content-Type", "application/json; charset=utf-8");
        res.end(
          JSON.stringify({
            ok: false,
            error: "whois_upstream_failed",
            message: e instanceof Error ? e.message : String(e),
          }),
        );
      }
    });
  };

  return {
    name: "ip-whois-proxy",
    configureServer(server) {
      attach(server);
    },
    configurePreviewServer(server) {
      attach(server);
    },
  };
}

module.exports = defineConfig(async ({ mode }) => {
  const plugins = [react(), apiProxyPlugin()];
  if (mode === "development") {
    try {
      // console.log("Success");
    } catch (error) {
      console.warn("Could not load", error.message);
    }
  }
  return {
    server: {
      host: true,
      port: 8080,
      strictPort: false,
      headers: {
        "Cache-Control": "no-store, no-cache, must-revalidate, max-age=0",
        Pragma: "no-cache",
        Expires: "0",
      },
    },
    preview: {
      host: true,
      port: 8080,
      strictPort: false,
      headers: {
        "Cache-Control": "no-store, no-cache, must-revalidate, max-age=0",
        Pragma: "no-cache",
        Expires: "0",
      },
    },
    plugins: plugins.filter(Boolean),
    resolve: {
      alias: {
        "@": path.resolve(__dirname, "./src"),
      },
    },
  };
});
