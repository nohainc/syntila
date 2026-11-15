// For a temporary development tunnel: expose only the sandbox webhook route.
import http from 'node:http';

const path = '/api/billing/sandbox/webhook';
const port = Number(process.env.PADDLE_SANDBOX_FORWARD_PORT || 18789);
const backendPort = Number(process.env.BACKEND_PORT || 8788);
http.createServer((request, response) => {
  if (request.method !== 'POST' || request.url !== path) {
    response.writeHead(404).end();
    return;
  }
  const upstream = http.request({
    hostname: '127.0.0.1', port: backendPort, path, method: 'POST',
    headers: { ...request.headers, host: `127.0.0.1:${backendPort}` },
  }, (result) => {
    response.writeHead(result.statusCode ?? 502, result.headers);
    result.pipe(response);
  });
  upstream.on('error', () => {
    if (!response.headersSent) response.writeHead(502);
    response.end();
  });
  request.pipe(upstream);
}).listen(port, '127.0.0.1', () => {
  console.log(`Paddle sandbox webhook forwarder listening on 127.0.0.1:${port}`);
});
