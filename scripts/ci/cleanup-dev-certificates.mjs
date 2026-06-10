#!/usr/bin/env node
// Prunes stale "Created via API" DEVELOPMENT certificates before a CI build.
//
// Each ephemeral CI runner lets Xcode cloud-signing mint a fresh development
// certificate, and the account-wide cap eventually blocks archiving with
// "maximum number of certificates" (which broke a release on 2026-06-10).
// This deletes only auto-minted development certs older than a grace window;
// named certificates (real machines) and distribution/Developer ID certs are
// never touched. Failures warn and exit 0 — cleanup must never block a
// release.
//
// Required env:
//   ASC_KEY_ID       App Store Connect API key ID
//   ASC_ISSUER_ID    App Store Connect API issuer ID
//   ASC_PRIVATE_KEY  The .p8 private key contents (PEM, multi-line)
//
// Optional env:
//   CERT_MAX_AGE_HOURS  Grace window before an auto-minted cert is pruned
//                       (default 48; the cert a concurrent run just minted
//                       stays alive).
//   CERT_CLEANUP_DRY_RUN  "true" to log what would be deleted without deleting.

import { createSign } from 'node:crypto';

const REQUIRED = ['ASC_KEY_ID', 'ASC_ISSUER_ID', 'ASC_PRIVATE_KEY'];

for (const key of REQUIRED) {
  if (!process.env[key]) {
    console.warn(`Cert cleanup skipped: missing env ${key}`);
    process.exit(0);
  }
}

const KEY_ID = process.env.ASC_KEY_ID;
const ISSUER_ID = process.env.ASC_ISSUER_ID;
const PRIVATE_KEY = process.env.ASC_PRIVATE_KEY;
const MAX_AGE_HOURS = Number(process.env.CERT_MAX_AGE_HOURS || 48);
const DRY_RUN = String(process.env.CERT_CLEANUP_DRY_RUN || '') === 'true';

const AUTO_MINTED_NAME = 'Created via API';
const CERT_LIFETIME_DAYS = 365;

function base64url(input) {
  return Buffer.from(input)
    .toString('base64')
    .replace(/=/g, '')
    .replace(/\+/g, '-')
    .replace(/\//g, '_');
}

function makeToken() {
  const header = base64url(JSON.stringify({ alg: 'ES256', kid: KEY_ID, typ: 'JWT' }));
  const payload = base64url(
    JSON.stringify({
      iss: ISSUER_ID,
      exp: Math.floor(Date.now() / 1000) + 20 * 60,
      aud: 'appstoreconnect-v1',
    })
  );
  const signer = createSign('SHA256');
  signer.update(`${header}.${payload}`);
  const signature = signer
    .sign({ key: PRIVATE_KEY, dsaEncoding: 'ieee-p1363' })
    .toString('base64')
    .replace(/=/g, '')
    .replace(/\+/g, '-')
    .replace(/\//g, '_');
  return `${header}.${payload}.${signature}`;
}

async function api(path, options = {}) {
  const response = await fetch(`https://api.appstoreconnect.apple.com${path}`, {
    ...options,
    headers: {
      Authorization: `Bearer ${makeToken()}`,
      ...(options.headers || {}),
    },
  });
  return response;
}

// Certificates expose no created date; auto-minted ones live for one year,
// so creation time is recovered from the expiration date.
function approximateCreatedAt(expirationDate) {
  const expires = new Date(expirationDate);
  return new Date(expires.getTime() - CERT_LIFETIME_DAYS * 24 * 3600 * 1000);
}

async function main() {
  const response = await api('/v1/certificates?limit=200');

  if (!response.ok) {
    console.warn(`Cert cleanup skipped: list failed with ${response.status}`);
    return;
  }

  const body = await response.json();
  const cutoff = new Date(Date.now() - MAX_AGE_HOURS * 3600 * 1000);

  const stale = (body.data || []).filter((cert) => {
    const attrs = cert.attributes || {};
    return (
      attrs.certificateType === 'DEVELOPMENT' &&
      attrs.displayName === AUTO_MINTED_NAME &&
      attrs.expirationDate &&
      approximateCreatedAt(attrs.expirationDate) < cutoff
    );
  });

  if (stale.length === 0) {
    console.log('Cert cleanup: nothing to prune.');
    return;
  }

  for (const cert of stale) {
    const label = `${cert.id} (expires ${cert.attributes.expirationDate})`;

    if (DRY_RUN) {
      console.log(`Cert cleanup dry-run: would revoke ${label}`);
      continue;
    }

    const deletion = await api(`/v1/certificates/${cert.id}`, { method: 'DELETE' });

    if (deletion.status === 204) {
      console.log(`Cert cleanup: revoked stale CI development cert ${label}`);
    } else {
      console.warn(`Cert cleanup: could not revoke ${label} (${deletion.status})`);
    }
  }
}

main().catch((error) => {
  console.warn(`Cert cleanup skipped: ${error.message}`);
  process.exit(0);
});
