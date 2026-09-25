// Egress proxy for ccc-run-auto. It runs in its own container and is the
// agent's only way out of the run's internal Docker network:
//
// - ANTHROPIC_BASE_URL points here, so API requests arrive as plain HTTP. Only
//   POST /v1/messages and /v1/messages/count_tokens are forwarded, carrying
//   the real API key (which only this container holds) in place of the
//   agent's placeholder. Requests that would make the API fetch a URL for the
//   agent are refused, and the body that was checked is what gets forwarded.
// - HTTPS_PROXY points here too: CONNECT tunnels are allowed to port 443 of
//   the hosts in CCC_AUTO_ALLOW_HOSTS (exact names, or *.suffix).
// - Everything else is refused. Each decision is logged to stdout.
'use strict';
const http = require('node:http');
const https = require('node:https');
const net = require('node:net');

const API_PATHS = new Set(['/v1/messages', '/v1/messages/count_tokens']);
const MAX_BODY = 32 * 1024 * 1024; // the API's own request size limit
// Not passed on: hop-by-hop headers, the agent's credentials, and headers
// that no longer match the re-serialized body.
const DROP_HEADERS = new Set([
  'host', 'connection', 'keep-alive', 'proxy-authorization', 'proxy-connection', 'te', 'trailer',
  'transfer-encoding', 'upgrade', 'expect', 'content-length', 'authorization', 'x-api-key', 'cookie',
]);

// Log lines carry agent-chosen strings; keep them to printable ASCII.
const printable = s => String(s).replace(/[^\x20-\x7e]/g, '?').slice(0, 200);

function hostAllowed(host, patterns) {
  host = host.toLowerCase().replace(/\.$/, '');
  return patterns.some(p => (p.startsWith('*.') ? host.endsWith(p.slice(1)) : host === p));
}

// True if a request body asks the API to fetch something for the agent: the
// MCP connector, the web fetch tool, or an image or document given by URL.
function fetchesUrl(value) {
  if (Array.isArray(value)) return value.some(fetchesUrl);
  if (value === null || typeof value !== 'object') return false;
  if (Object.hasOwn(value, 'mcp_servers')) return true;
  if (typeof value.type === 'string' && /^(web_fetch|mcp)/.test(value.type)) return true;
  if (value.source && value.source.type === 'url') return true;
  return Object.values(value).some(fetchesUrl);
}

function createProxy({ apiKey, allowHosts, upstream = 'https://api.anthropic.com', log = console.log }) {
  const patterns = allowHosts.map(p => p.toLowerCase());
  const base = new URL(upstream);
  const client = base.protocol === 'https:' ? https : http;
  const agent = new client.Agent({ keepAlive: true });

  const server = http.createServer((req, res) => {
    const deny = (status, why) => {
      if (res.headersSent) return;
      log(`deny ${printable(req.method)} ${printable(req.url)} ${status} ${why}`);
      res.writeHead(status, { 'content-type': 'text/plain' }).end(`ccc-auto-proxy: ${why}\n`);
    };
    req.on('error', () => res.destroy());

    if (!req.url.startsWith('/')) return deny(403, 'only HTTPS to allowed hosts can leave the capsule');
    const q = req.url.indexOf('?');
    const path = q < 0 ? req.url : req.url.slice(0, q);
    if (req.method !== 'POST' || !API_PATHS.has(path)) return deny(403, 'not an allowed API request');
    const encoding = req.headers['content-encoding'];
    if (encoding && encoding !== 'identity') return deny(415, 'compressed request bodies are not supported');

    const chunks = [];
    let size = 0;
    req.on('data', chunk => {
      size += chunk.length;
      if (size > MAX_BODY) {
        deny(413, 'request body too large');
        req.destroy();
      } else {
        chunks.push(chunk);
      }
    });
    req.on('end', () => {
      if (res.headersSent) return;
      let body;
      try {
        body = JSON.parse(Buffer.concat(chunks).toString('utf8'));
        if (fetchesUrl(body)) return deny(403, 'requests that make the API fetch URLs are not allowed');
        body = Buffer.from(JSON.stringify(body));
      } catch {
        return deny(400, 'the request body must be JSON');
      }

      const headers = {};
      for (const [name, value] of Object.entries(req.headers)) {
        if (!DROP_HEADERS.has(name)) headers[name] = value;
      }
      headers['x-api-key'] = apiKey;
      headers['content-length'] = body.length;
      const up = client.request(new URL(req.url, base), { method: 'POST', headers, agent }, upRes => {
        log(`allow POST ${path} ${upRes.statusCode}`);
        const out = { ...upRes.headers };
        delete out.connection;
        delete out['keep-alive'];
        delete out['transfer-encoding'];
        res.writeHead(upRes.statusCode, out);
        upRes.on('error', () => res.destroy());
        upRes.pipe(res);
      });
      up.on('error', err => {
        if (res.headersSent) return res.destroy();
        log(`fail POST ${path} ${err.code || err.message}`);
        res.writeHead(502, { 'content-type': 'text/plain' }).end(`ccc-auto-proxy: API request failed: ${err.code || err.message}\n`);
      });
      res.on('close', () => { if (!res.writableFinished) up.destroy(); });
      up.end(body);
    });
  });

  server.on('connect', (req, sock, head) => {
    sock.on('error', () => {});
    const target = printable(req.url);
    const m = /^([a-z0-9.-]+):(\d+)$/i.exec(req.url);
    if (!m || m[2] !== '443' || !hostAllowed(m[1], patterns)) {
      log(`deny CONNECT ${target} not in CCC_AUTO_ALLOW_HOSTS`);
      const msg = `ccc-auto-proxy: ${target} is not in CCC_AUTO_ALLOW_HOSTS\n`;
      return sock.end(`HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain\r\nContent-Length: ${msg.length}\r\nConnection: close\r\n\r\n${msg}`);
    }
    let connected = false;
    const up = net.connect(443, m[1], () => {
      connected = true;
      log(`allow CONNECT ${target}`);
      sock.write('HTTP/1.1 200 Connection Established\r\n\r\n');
      if (head.length) up.write(head);
      up.pipe(sock);
      sock.pipe(up);
    });
    up.on('error', err => {
      if (connected) return sock.destroy();
      log(`fail CONNECT ${target} ${err.code || err.message}`);
      sock.end('HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n');
    });
    up.on('close', () => sock.destroy());
    sock.on('close', () => up.destroy());
  });

  return server;
}

module.exports = { createProxy, hostAllowed };

if (require.main === module) {
  const apiKey = process.env.ANTHROPIC_API_KEY;
  if (!apiKey) {
    console.error('ccc-auto-proxy: ANTHROPIC_API_KEY is not set');
    process.exit(1);
  }
  const allowHosts = (process.env.CCC_AUTO_ALLOW_HOSTS || '').split(/[\s,]+/).filter(Boolean);
  createProxy({ apiKey, allowHosts }).listen(8080, () => {
    console.log(`listening; allowed hosts: ${allowHosts.join(' ') || 'none'}`);
  });
}
