import { spawn } from "node:child_process";
import { readFile, mkdtemp, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { fileURLToPath } from "node:url";

export const name = "dsh-screenshot";
export const inject = [];

const CHUNK_SIZE = 64 * 1024;
const MAX_BODY_BYTES = 64 * 1024;

const moduleDir = fileURLToPath(new URL(".", import.meta.url));
const PS_SCRIPT = join(moduleDir, "screenshot.ps1");

function sendJson(res, status, obj) {
  res.statusCode = status;
  res.setHeader("Content-Type", "application/json; charset=utf-8");
  res.setHeader("Cache-Control", "no-store");
  res.end(JSON.stringify(obj));
}

async function readJsonBody(req) {
  const chunks = [];
  let total = 0;
  for await (const c of req) {
    total += c.length;
    if (total > MAX_BODY_BYTES) return null;
    chunks.push(c);
  }
  const raw = Buffer.concat(chunks).toString("utf8");
  if (!raw) return {};
  try {
    return JSON.parse(raw);
  } catch {
    return {};
  }
}

async function* bufferStream(buf) {
  let offset = 0;
  while (offset < buf.length) {
    yield buf.subarray(offset, Math.min(offset + CHUNK_SIZE, buf.length));
    offset += CHUNK_SIZE;
  }
}

function runCapture(outPath) {
  return new Promise((resolve, reject) => {
    const ps = spawn(
      "powershell.exe",
      ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", PS_SCRIPT],
      {
        env: { ...process.env, DSH_SHOT_OUT: outPath },
        windowsHide: true,
        stdio: "ignore",
      }
    );
    ps.on("error", reject);
    ps.on("close", (code) => resolve(code ?? 0));
  });
}

async function captureRegion() {
  const dir = await mkdtemp(join(tmpdir(), "dsh-shot-"));
  const outPath = join(dir, "shot.png");
  try {
    const code = await runCapture(outPath);
    if (code !== 0) return null;
    try {
      const st = await stat(outPath);
      if (!st.isFile() || st.size === 0) return null;
      return await readFile(outPath);
    } catch {
      return null;
    }
  } finally {
    await rm(dir, { recursive: true, force: true }).catch(() => {});
  }
}

export function apply(ctx, config = {}) {
  const log = (m) => ctx.logger?.info?.(`[dsh-screenshot] ${m}`);
  const unregisters = [];

  ctx.inject(["webServer"], (httpCtx) => {
    const webServer = httpCtx.get("webServer");
    if (!webServer) {
      log("webServer unavailable — route not mounted");
      return;
    }

    const unreg = webServer.register({
      kind: "exact",
      path: "/screenshot/api/capture",
      handler: async (req, res) => {
        const body = await readJsonBody(req);
        if (body === null) {
          sendJson(res, 413, { ok: false, code: "bad-request", message: "body too large" });
          return;
        }
        const sessionId = body?.sessionId;
        if (!sessionId || typeof sessionId !== "string") {
          sendJson(res, 400, { ok: false, code: "bad-request", message: "sessionId required" });
          return;
        }

        const png = await captureRegion();
        if (!png) {
          sendJson(res, 200, { ok: true, cancelled: true });
          return;
        }

        const fileUploads = ctx.get("fileUploads");
        const sessionController = ctx.get("sessionController");
        if (!fileUploads?.uploadStream || !sessionController?.prompt) {
          sendJson(res, 500, { ok: false, code: "internal", message: "attachment services unavailable" });
          return;
        }

        try {
          const receipt = await fileUploads.uploadStream({
            sessionId,
            data: bufferStream(png),
            name: `screenshot-${Date.now()}.png`,
          });
          if (!receipt?.receiptId) {
            throw new Error("uploadStream returned no receiptId");
          }
          const requestId = randomUUID();
          const ac = new AbortController();
          await sessionController.prompt(
            {
              requestId,
              sessionId,
              mode: "queue",
              content: [{ type: "file", receiptId: receipt.receiptId }],
            },
            ac.signal
          );
          sendJson(res, 200, { ok: true, sent: true, requestId });
        } catch (err) {
          log(`send failed: ${err?.message ?? err}`);
          sendJson(res, 500, { ok: false, code: "internal", message: err?.message ?? String(err) });
        }
      },
    });

    if (typeof unreg === "function") unregisters.push(unreg);
    log("route mounted: /screenshot/api/capture");
  });

  return async function dispose() {
    for (const u of unregisters.splice(0)) {
      try {
        u();
      } catch {
        // best effort
      }
    }
    log("disposed");
  };
}
