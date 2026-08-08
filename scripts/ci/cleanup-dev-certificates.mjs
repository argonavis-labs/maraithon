#!/usr/bin/env node
// Prunes ephemeral "Created via API" development certificates before CI.
//
// Each ephemeral runner lets Xcode API-key signing mint a fresh development
// certificate. A burst of releases can reach Apple's account-wide cap before
// the certificates become old enough for age-only cleanup. This keeps only a
// small newest set and also removes old certificates. Named certificates (real
// machines), distribution certificates, and Developer ID certificates are
// never touched.
//
// Required env:
//   ASC_KEY_ID       App Store Connect API key ID
//   ASC_ISSUER_ID    App Store Connect API issuer ID
//   ASC_PRIVATE_KEY  The .p8 private key contents (PEM, multi-line)
//
// Optional env:
//   CERT_RETAIN_COUNT     Number of newest auto-minted certificates to preserve
//                         even during a burst (default 2).
//   CERT_MAX_AGE_HOURS    Maximum age for preserved certificates (default 48).
//   CERT_CLEANUP_DRY_RUN  "true" to log what would be deleted without deleting.

import { createSign } from 'node:crypto';

const REQUIRED = ['ASC_KEY_ID', 'ASC_ISSUER_ID', 'ASC_PRIVATE_KEY'];

for (const key of REQUIRED) {
  if (!process.env[key]) {
    console.error(`Cert cleanup failed: missing env ${key}`);
    process.exit(1);
  }
}

const KEY_ID = process.env.ASC_KEY_ID;
const ISSUER_ID = process.env.ASC_ISSUER_ID;
const PRIVATE_KEY = process.env.ASC_PRIVATE_KEY;
const RETAIN_COUNT = Number(process.env.CERT_RETAIN_COUNT || 2);
const MAX_AGE_HOURS = Number(process.env.CERT_MAX_AGE_HOURS || 48);
const DRY_RUN = String(process.env.CERT_CLEANUP_DRY_RUN || '') === 'true';

const AUTO_MINTED_NAME = 'Created via API';
const AUTO_MINTED_TYPES = new Set(['DEVELOPMENT', 'IOS_DEVELOPMENT']);
const CERT_LIFETIME_DAYS = 365;

if (!Number.isInteger(RETAIN_COUNT) || RETAIN_COUNT < 0) {
  console.error('CERT_RETAIN_COUNT must be a non-negative integer');
  process.exit(1);
}

if (!Number.isFinite(MAX_AGE_HOURS) || MAX_AGE_HOURS < 0) {
  console.error('CERT_MAX_AGE_HOURS must be a non-negative number');
  process.exit(1);
}

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
    throw new Error(`certificate list failed with ${response.status}`);
  }

  const body = await response.json();
  const cutoff = new Date(Date.now() - MAX_AGE_HOURS * 3600 * 1000);
  const autoMinted = (body.data || [])
    .filter((cert) => {
      const attrs = cert.attributes || {};
      return (
        AUTO_MINTED_TYPES.has(attrs.certificateType) &&
        attrs.displayName === AUTO_MINTED_NAME &&
        attrs.expirationDate &&
        Number.isFinite(new Date(attrs.expirationDate).getTime())
      );
    })
    // These certificates share the same lifetime, so expiration order is also
    // creation order even though Apple's API does not expose a created date.
    .sort(
      (left, right) =>
        new Date(right.attributes.expirationDate) -
        new Date(left.attributes.expirationDate)
    );

  const prune = autoMinted.filter((cert, index) => {
    const tooMany = index >= RETAIN_COUNT;
    const tooOld = approximateCreatedAt(cert.attributes.expirationDate) < cutoff;
    return tooMany || tooOld;
  });

  console.log(
    `Cert cleanup: found ${autoMinted.length} ephemeral development certificate(s); ` +
      `retaining at most ${RETAIN_COUNT}.`
  );

  if (prune.length === 0) {
    console.log('Cert cleanup: nothing to prune.');
    return;
  }

  let failures = 0;

  for (const cert of prune) {
    const label = `${cert.id} (expires ${cert.attributes.expirationDate})`;

    if (DRY_RUN) {
      console.log(`Cert cleanup dry-run: would revoke ${label}`);
      continue;
    }

    const deletion = await api(`/v1/certificates/${cert.id}`, { method: 'DELETE' });

    if (deletion.status === 204) {
      console.log(`Cert cleanup: revoked ephemeral CI development cert ${label}`);
    } else if (deletion.status === 404) {
      console.log(`Cert cleanup: ${label} was already revoked`);
    } else {
      failures += 1;
      console.warn(`Cert cleanup: could not revoke ${label} (${deletion.status})`);
    }
  }

  if (failures > 0) {
    throw new Error(`could not revoke ${failures} ephemeral certificate(s)`);
  }
}

main().catch((error) => {
  console.error(`Cert cleanup failed: ${error.message}`);
  process.exit(1);
});
