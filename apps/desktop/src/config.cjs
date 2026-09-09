// One validated origin per installation; development may target loopback HTTP.
const {createHash} = require('node:crypto');
const raw = process.env.MARAITHON_DESKTOP_ORIGIN || 'https://maraithon.com';
const parsed = new URL(raw);
if (parsed.username || parsed.password || parsed.search || parsed.hash || parsed.pathname !== '/' ||
    !(parsed.protocol === 'https:' || (parsed.protocol === 'http:' && ['localhost', '127.0.0.1', '[::1]'].includes(parsed.hostname)))) {
  throw new Error('MARAITHON_DESKTOP_ORIGIN must be an HTTPS origin or a loopback HTTP origin.');
}
const origin = parsed.origin;
const partition = `persist:maraithon-${createHash('sha256').update(origin).digest('hex').slice(0, 12)}`;
const sameOrigin = value => {
  try { return new URL(value).origin === origin; } catch { return false; }
};
module.exports = {origin, partition, sameOrigin};
