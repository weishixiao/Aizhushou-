#!/usr/bin/env node
// AIReverse project preview tooling (Freebuff).
//   - Default mode : serve the static preview site on 0.0.0.0:$PORT
//                    (serves dist/ when built, otherwise docs/)
//   - --build mode : emit the site into dist/ and exit (deploy build step)
//
// Uses only Node builtins so no dependencies need to be installed.

import { createServer } from "node:http";
import { copyFile, mkdir, readFile, readdir, stat } from "node:fs/promises";
import { existsSync } from "node:fs";
import { extname, join, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(fileURLToPath(new URL("..", import.meta.url)));
const DOCS = join(ROOT, "docs");
const DIST = join(ROOT, "dist");

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".ico": "image/x-icon",
  ".md": "text/markdown; charset=utf-8",
  ".txt": "text/plain; charset=utf-8",
  ".woff2": "font/woff2",
};

async function build() {
  await mkdir(DIST, { recursive: true });
  const entries = await readdir(DOCS, { withFileTypes: true });
  let copied = 0;
  for (const entry of entries) {
    if (entry.isFile()) {
      await copyFile(join(DOCS, entry.name), join(DIST, entry.name));
      copied += 1;
    }
  }
  console.log(`Preview site built: ${copied} file(s) copied to ${DIST}`);
}

async function serve() {
  const port = Number(process.env.PORT) || 3000;
  const root = existsSync(join(DIST, "index.html")) ? DIST : DOCS;

  const server = createServer(async (req, res) => {
    try {
      const urlPath = decodeURIComponent((req.url || "/").split("?")[0]);
      let filePath = resolve(root, "." + (urlPath === "/" ? "/index.html" : urlPath));
      if (filePath !== root && !filePath.startsWith(root + sep)) {
        res.writeHead(403, { "Content-Type": "text/plain; charset=utf-8" });
        res.end("403 Forbidden");
        return;
      }
      let info = await stat(filePath).catch(() => null);
      if (info && info.isDirectory()) {
        filePath = join(filePath, "index.html");
        info = await stat(filePath).catch(() => null);
      }
      if (!info || !info.isFile()) {
        res.writeHead(404, { "Content-Type": "text/plain; charset=utf-8" });
        res.end("404 Not Found");
        return;
      }
      const data = await readFile(filePath);
      res.writeHead(200, {
        "Content-Type": MIME[extname(filePath)] || "application/octet-stream",
      });
      res.end(data);
    } catch {
      res.writeHead(500, { "Content-Type": "text/plain; charset=utf-8" });
      res.end("500 Internal Server Error");
    }
  });

  server.listen(port, "0.0.0.0", () => {
    console.log(`AIReverse preview serving ${root} on http://0.0.0.0:${port}`);
  });
}

if (process.argv.includes("--build")) {
  await build();
} else {
  await serve();
}
