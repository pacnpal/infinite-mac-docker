// Front server for the self-hosted image (see docker/README.md).
//
// - Serves disk chunks (/Disk/<hash>.chunk) and self-hosted CD-ROM media
//   (/CD-ROMs/build/media/<hash>.media) straight from disk, so neither has to
//   go through Workers static assets (which hash every file at startup and
//   cap the file count).
// - Proxies everything else, including WebSockets, to wrangler/workerd
//   running the regular Infinite Mac worker on an internal port.
// - On start, serves the build baked into the image, runs docker/import.sh in
//   the background to download and import everything into /data, then
//   restarts wrangler on the full build when that finishes.
// - Shows import progress at /_import.

import {spawn} from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import net from "node:net";
import path from "node:path";

const PORT = parseInt(process.env.PORT ?? "3127", 10);
const WRANGLER_PORT = parseInt(process.env.WRANGLER_PORT ?? "3128", 10);
const DATA_DIR = process.env.DATA_DIR ?? "/data";
const APP_DIR = process.env.APP_DIR ?? "/app";
const WORK_DIR = path.join(DATA_DIR, "work");
const REPO_DIR = path.join(WORK_DIR, "repo");
const STATUS_PATH = path.join(WORK_DIR, "status.json");

const BAKED_BUILD = path.join(APP_DIR, "baked", "build");
const FULL_BUILD = path.join(WORK_DIR, "build");

// Searched in order: chunks imported into /data first, then the ones baked
// into the image (so System 1 through 7.5.5 work while importing).
const DISK_DIRS = [
    path.join(REPO_DIR, "Images", "build"),
    path.join(APP_DIR, "baked", "Images", "build"),
];
const MEDIA_DIR = path.join(REPO_DIR, "CD-ROMs", "build", "media");

const CHUNK_RE = /^[0-9a-f]{16,64}\.chunk$/;
const MEDIA_RE = /^[0-9a-f]{16,64}\.media$/;
const IMMUTABLE = `public, max-age=${60 * 60 * 24 * 30}, immutable`;

let wrangler = null;
let wranglerReady = false;
let wranglerRestartTimer = null;
let activeBuild = null;
let importProcess = null;
let importState = {phase: "starting", startedAt: new Date().toISOString()};

function main() {
    const server = http.createServer(handleRequest);
    server.on("upgrade", handleUpgrade);
    server.listen(PORT, "0.0.0.0", () => {
        log(`listening on http://0.0.0.0:${PORT}`);
    });

    const startBuild =
        hasBuild(FULL_BUILD) && isImportCurrent() ? FULL_BUILD : BAKED_BUILD;
    startWrangler(startBuild);

    if (process.env.INFINITE_MAC_IMPORT === "none") {
        setImportState({phase: "disabled"});
    } else {
        runImport();
    }

    for (const signal of ["SIGTERM", "SIGINT"]) {
        process.on(signal, () => {
            log(`${signal}, shutting down`);
            importProcess?.kill("SIGTERM");
            stopWrangler().then(() => process.exit(0));
        });
    }
}

function handleRequest(req, res) {
    try {
        routeRequest(req, res);
    } catch (err) {
        log(`error handling ${req.method} ${req.url}: ${err.message}`);
        if (!res.headersSent) {
            res.writeHead(500, {"Content-Type": "text/plain"});
        }
        res.end("Internal error");
    }
}

function routeRequest(req, res) {
    let url;
    try {
        url = new URL(req.url ?? "/", "http://localhost");
    } catch {
        res.writeHead(400, {"Content-Type": "text/plain"}).end("Bad request");
        return;
    }
    const [, first, ...rest] = url.pathname.split("/");

    if (first === "Disk" && rest.length === 1 && CHUNK_RE.test(rest[0])) {
        return serveFile(req, res, findFile(DISK_DIRS, rest[0]), {
            "Content-Type": "application/octet-stream",
            "Cache-Control": IMMUTABLE,
        });
    }
    if (
        url.pathname.startsWith("/CD-ROMs/build/media/") &&
        rest.length === 3 &&
        MEDIA_RE.test(rest[2])
    ) {
        return serveFile(req, res, findFile([MEDIA_DIR], rest[2]), {
            "Content-Type": "application/octet-stream",
            "Cache-Control": IMMUTABLE,
        });
    }
    if (url.pathname === "/_import" || url.pathname === "/_import.json") {
        return serveStatus(res, url.pathname.endsWith(".json"));
    }
    proxyRequest(req, res);
}

function serveFile(req, res, filePath, headers) {
    if (req.method !== "GET" && req.method !== "HEAD") {
        res.writeHead(405).end();
        return;
    }
    if (!filePath) {
        res.writeHead(404, {"Content-Type": "text/plain"}).end("Not found");
        return;
    }
    const {size} = fs.statSync(filePath);
    let start = 0;
    let end = size - 1;
    let status = 200;
    const range = /^bytes=(\d*)-(\d*)$/.exec(req.headers.range ?? "");
    if (range && (range[1] || range[2])) {
        if (range[1]) {
            start = parseInt(range[1], 10);
            end = range[2] ? Math.min(parseInt(range[2], 10), size - 1) : end;
        } else {
            start = Math.max(size - parseInt(range[2], 10), 0);
        }
        if (start > end || start >= size) {
            res.writeHead(416, {"Content-Range": `bytes */${size}`}).end();
            return;
        }
        status = 206;
        headers["Content-Range"] = `bytes ${start}-${end}/${size}`;
    }
    res.writeHead(status, {
        ...headers,
        "Accept-Ranges": "bytes",
        "Content-Length": String(end - start + 1),
    });
    if (req.method === "HEAD") {
        res.end();
        return;
    }
    fs.createReadStream(filePath, {start, end}).pipe(res);
}

function proxyRequest(req, res) {
    if (!wranglerReady) {
        res.writeHead(503, {"Content-Type": "text/plain", "Retry-After": "2"});
        res.end("Starting up, try again in a moment.");
        return;
    }
    const upstream = http.request(
        {
            host: "127.0.0.1",
            port: WRANGLER_PORT,
            method: req.method,
            path: req.url,
            headers: req.headers,
        },
        upstreamRes => {
            res.writeHead(
                upstreamRes.statusCode ?? 502,
                upstreamRes.statusMessage,
                upstreamRes.headers
            );
            upstreamRes.pipe(res);
        }
    );
    upstream.on("error", err => {
        if (!res.headersSent) {
            res.writeHead(502, {"Content-Type": "text/plain"});
        }
        res.end(`Upstream error: ${err.message}`);
    });
    req.pipe(upstream);
}

function handleUpgrade(req, socket, head) {
    if (!wranglerReady) {
        socket.destroy();
        return;
    }
    const upstream = net.connect(WRANGLER_PORT, "127.0.0.1", () => {
        const headerLines = [];
        for (let i = 0; i < req.rawHeaders.length; i += 2) {
            headerLines.push(`${req.rawHeaders[i]}: ${req.rawHeaders[i + 1]}`);
        }
        upstream.write(
            `${req.method} ${req.url} HTTP/${req.httpVersion}\r\n` +
                headerLines.join("\r\n") +
                "\r\n\r\n"
        );
        if (head?.length) {
            upstream.write(head);
        }
        upstream.pipe(socket);
        socket.pipe(upstream);
    });
    const close = () => {
        upstream.destroy();
        socket.destroy();
    };
    upstream.on("error", close);
    socket.on("error", close);
}

function serveStatus(res, asJson) {
    const status = {...importState, activeBuild: buildName(activeBuild)};
    if (asJson) {
        res.writeHead(200, {
            "Content-Type": "application/json",
            "Cache-Control": "no-store",
        });
        res.end(JSON.stringify(status, null, 2));
        return;
    }
    const rows = Object.entries(status)
        .map(([k, v]) => `<tr><th>${escape(k)}</th><td>${escape(v)}</td></tr>`)
        .join("");
    res.writeHead(200, {
        "Content-Type": "text/html; charset=utf-8",
        "Cache-Control": "no-store",
    });
    res.end(
        `<!doctype html><meta charset="utf-8"><meta http-equiv="refresh" content="10">` +
            `<title>Infinite Mac import</title>` +
            `<style>body{font:14px system-ui;margin:2em}th{text-align:left;padding-right:1em}</style>` +
            `<h1>Infinite Mac import</h1><table>${rows}</table>` +
            `<p>Refreshes every 10 seconds. <a href="/">Back to Infinite Mac</a></p>`
    );
}

// --- wrangler ---------------------------------------------------------------

function startWrangler(buildDir) {
    clearTimeout(wranglerRestartTimer);
    wranglerRestartTimer = null;
    activeBuild = buildDir;
    wranglerReady = false;
    const config = path.join(buildDir, "infinite_mac", "wrangler.json");
    log(`starting wrangler on ${buildName(buildDir)} build`);
    const child = spawn(
        "wrangler",
        [
            "dev",
            "--config",
            config,
            "--ip",
            "127.0.0.1",
            "--port",
            String(WRANGLER_PORT),
            "--persist-to",
            path.join(DATA_DIR, "state"),
            "--show-interactive-dev-session=false",
            "--var",
            `LOCAL_MEDIA_ORIGIN:http://127.0.0.1:${PORT}`,
        ],
        {stdio: ["ignore", "pipe", "pipe"], cwd: path.dirname(config)}
    );
    wrangler = child;
    const onOutput = data => {
        const text = data.toString();
        if (!wranglerReady && text.includes("Ready on")) {
            wranglerReady = true;
            log(`wrangler ready (${buildName(buildDir)} build)`);
        }
        // The module table wrangler prints at startup is noise.
        for (const line of text.split("\n")) {
            if (line.trim() && !/^[│├┌└]/.test(line)) {
                process.stdout.write(`[wrangler] ${line}\n`);
            }
        }
    };
    child.stdout.on("data", onOutput);
    child.stderr.on("data", onOutput);
    child.on("exit", (code, signal) => {
        if (wrangler !== child) {
            return; // Replaced on purpose.
        }
        wranglerReady = false;
        log(`wrangler exited (${signal ?? code}), restarting in 2s`);
        wranglerRestartTimer = setTimeout(() => {
            wranglerRestartTimer = null;
            // Skip if something else started or stopped wrangler meanwhile.
            if (wrangler === child) {
                startWrangler(activeBuild);
            }
        }, 2000);
    });
}

function stopWrangler() {
    clearTimeout(wranglerRestartTimer);
    wranglerRestartTimer = null;
    const child = wrangler;
    wrangler = null;
    wranglerReady = false;
    if (!child || child.exitCode !== null) {
        return Promise.resolve();
    }
    return new Promise(resolve => {
        child.once("exit", resolve);
        child.kill("SIGTERM");
        setTimeout(() => child.kill("SIGKILL"), 10000).unref();
    });
}

// --- import -----------------------------------------------------------------

function runImport() {
    setImportState({phase: "running", detail: "starting"});
    importProcess = spawn(
        "sh",
        [path.join(APP_DIR, "src", "docker", "import.sh")],
        {
            stdio: ["ignore", "pipe", "pipe"],
        }
    );
    const onOutput = data => {
        for (const line of data.toString().split(/[\r\n]+/)) {
            if (!line.trim()) {
                continue;
            }
            const phase = /^==> (.*)$/.exec(line);
            if (phase && phase[1] === "Build ready") {
                switchToFullBuild();
            } else if (phase?.[1].startsWith("CD-ROMs imported")) {
                setImportState({cdroms: phase[1]});
            } else if (phase) {
                setImportState({detail: phase[1]});
            }
            // Per-chunk progress lines would flood the container log.
            if (!/^Chunking .*%$/.test(line)) {
                process.stdout.write(`[import] ${line}\n`);
            }
        }
    };
    importProcess.stdout.on("data", onOutput);
    importProcess.stderr.on("data", onOutput);
    importProcess.on("exit", code => {
        importProcess = null;
        if (code !== 0) {
            setImportState({
                phase: "failed",
                detail: `import.sh exited with ${code}; see the container log`,
                finishedAt: new Date().toISOString(),
            });
            log("import failed, still serving the baked build");
            return;
        }
        setImportState({phase: "done", finishedAt: new Date().toISOString()});
        if (activeBuild !== FULL_BUILD && hasBuild(FULL_BUILD)) {
            switchToFullBuild();
        }
    });
}

// Restarts wrangler on the build import.sh just finished. Switches are
// serialized so back-to-back builds can't leave two wranglers running.
let switching = Promise.resolve();
function switchToFullBuild() {
    switching = switching.then(async () => {
        log("new build ready, switching to it");
        await stopWrangler();
        startWrangler(FULL_BUILD);
    });
}

function setImportState(update) {
    importState = {...importState, ...update};
    try {
        fs.mkdirSync(WORK_DIR, {recursive: true});
        fs.writeFileSync(STATUS_PATH, JSON.stringify(importState, null, 2));
    } catch {
        // Status is best-effort.
    }
}

// The full build in /data is usable as-is when import.sh built it from the
// same source as this image (settings changes are picked up by the import run,
// which restarts wrangler if it rebuilt).
function isImportCurrent() {
    try {
        const source = fs.readFileSync(
            path.join(APP_DIR, "src", ".source-hash"),
            "utf8"
        );
        return readBuiltFrom().startsWith(source.trim() + " ");
    } catch {
        return false;
    }
}

function readBuiltFrom() {
    try {
        return fs
            .readFileSync(path.join(WORK_DIR, "built-from"), "utf8")
            .trim();
    } catch {
        return "";
    }
}

// --- helpers ----------------------------------------------------------------

function hasBuild(buildDir) {
    return fs.existsSync(path.join(buildDir, "infinite_mac", "wrangler.json"));
}

function findFile(dirs, name) {
    for (const dir of dirs) {
        const candidate = path.join(dir, name);
        if (fs.existsSync(candidate)) {
            return candidate;
        }
    }
    return null;
}

function buildName(buildDir) {
    return buildDir === FULL_BUILD ? "full" : "baked";
}

function escape(value) {
    return String(value).replace(
        /[&<>"]/g,
        c => ({"&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;"})[c]
    );
}

function log(message) {
    process.stdout.write(`[infinite-mac] ${message}\n`);
}

main();
