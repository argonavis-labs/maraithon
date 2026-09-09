// A bounded loopback PKCE handoff. Secrets never enter the renderer or logs.
const http = require('node:http');
const {randomBytes, createHash, timingSafeEqual} = require('node:crypto');
const {shell} = require('electron');
const {origin} = require('./config.cjs');
let pending;
function cancelSignIn() {
  if (!pending) return;
  clearTimeout(pending.timeout);
  pending.server.close();
  pending = undefined;
}
async function startSignIn(browserSession, onComplete, onError) {
  // Reuse the active handoff when the member clicks again in the welcome window.
  if (pending?.url) { await shell.openExternal(pending.url); return; }
  const state = randomBytes(32).toString('base64url');
  const verifier = randomBytes(32).toString('base64url');
  const challenge = createHash('sha256').update(verifier).digest('base64url');
  let exchanging = false;
  const server = http.createServer(async (req, res) => {
    let url;
    try { url = new URL(req.url || '/', 'http://127.0.0.1'); }
    catch { res.writeHead(400); res.end('Invalid sign-in callback.'); return; }
    const supplied = url.searchParams.get('state') || '';
    const validState = Buffer.byteLength(supplied) === Buffer.byteLength(state) && timingSafeEqual(Buffer.from(supplied), Buffer.from(state));
    if (req.method !== 'GET' || url.pathname !== '/callback' || !validState || exchanging) {
      res.writeHead(400); res.end('Invalid sign-in callback.'); return;
    }
    const ticket = url.searchParams.get('ticket');
    if (!ticket || ticket.length > 4096) { res.writeHead(400); res.end('Missing sign-in ticket.'); return; }
    exchanging = true;
    try {
      const response = await browserSession.fetch(`${origin}/desktop/exchange`, {
        method: 'POST', credentials: 'include', headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({ticket, verifier}), signal: AbortSignal.timeout(15000)
      });
      if (!response.ok) throw new Error('Sign-in expired or was not accepted. Please try again.');
      res.writeHead(200, {'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store', 'Referrer-Policy': 'no-referrer', 'Content-Security-Policy': "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'"});
      res.end('<!doctype html><meta charset="utf-8"><title>Signed in to Maraithon</title><body style="margin:15vh auto;max-width:420px;padding:24px;font:16px/1.6 system-ui;color:#252116;background:#fcfcfa"><h1 style="font-size:26px;font-weight:500">You’re signed in.</h1><p>Your workspace is ready in Maraithon. You can close this tab.</p></body>');
      cancelSignIn();
      onComplete();
    } catch (error) {
      res.writeHead(502, {'Content-Type': 'text/plain', 'Cache-Control': 'no-store'});
      res.end('Could not finish signing in. Return to Maraithon and try again.');
      cancelSignIn();
      onError(error);
    }
  });
  server.requestTimeout = 20000;
  server.headersTimeout = 10000;
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
  const timeout = setTimeout(() => { cancelSignIn(); onError(new Error('Sign-in timed out. Please try again.')); }, 10 * 60 * 1000);
  timeout.unref();
  pending = {server, timeout};
  const callback = `http://127.0.0.1:${server.address().port}/callback`;
  pending.url = `${origin}/desktop/auth?${new URLSearchParams({state, challenge, callback})}`;
  try { await shell.openExternal(pending.url); }
  catch (error) { cancelSignIn(); throw error; }
}
module.exports = {startSignIn, cancelSignIn};
