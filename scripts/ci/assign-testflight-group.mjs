#!/usr/bin/env node
// Adds the just-uploaded TestFlight build to a beta tester group via the
// App Store Connect API.
//
// Required env:
//   ASC_KEY_ID              App Store Connect API key ID
//   ASC_ISSUER_ID           App Store Connect API issuer ID
//   ASC_PRIVATE_KEY         The .p8 private key contents (PEM, multi-line)
//   ASC_APP_ID              App Store Connect numeric app ID
//   ASC_VERSION_STRING      Marketing version (e.g. "1.0")
//   ASC_BUILD_NUMBER        Build number to match (e.g. "202606090100")
//   TESTFLIGHT_GROUP_NAME   Beta group display name (e.g. "Internal Testers")
//
// Polls until the build is processed, then attaches it to the group.

import { createHmac, createSign } from 'node:crypto';

const REQUIRED = [
  'ASC_KEY_ID',
  'ASC_ISSUER_ID',
  'ASC_PRIVATE_KEY',
  'ASC_APP_ID',
  'ASC_VERSION_STRING',
  'ASC_BUILD_NUMBER',
  'TESTFLIGHT_GROUP_NAME',
];

for (const key of REQUIRED) {
  if (!process.env[key]) {
    console.error(`Missing required env: ${key}`);
    process.exit(1);
  }
}

const KEY_ID = process.env.ASC_KEY_ID;
const ISSUER_ID = process.env.ASC_ISSUER_ID;
const PRIVATE_KEY = process.env.ASC_PRIVATE_KEY;
const APP_ID = process.env.ASC_APP_ID;
const VERSION = process.env.ASC_VERSION_STRING;
const BUILD_NUMBER = process.env.ASC_BUILD_NUMBER;
const GROUP_NAME = process.env.TESTFLIGHT_GROUP_NAME;

const POLL_INTERVAL_SECONDS = Number(process.env.ASC_POLL_INTERVAL_SECONDS || 60);
const POLL_TIMEOUT_MINUTES = Number(process.env.ASC_POLL_TIMEOUT_MINUTES || 45);

function base64url(input) {
  return Buffer.from(input)
    .toString('base64')
    .replace(/=/g, '')
    .replace(/\+/g, '-')
    .replace(/\//g, '_');
}

function makeToken() {
  const header = base64url(
    JSON.stringify({ alg: 'ES256', kid: KEY_ID, typ: 'JWT' })
  );
  const now = Math.floor(Date.now() / 1000);
  const payload = base64url(
    JSON.stringify({
      iss: ISSUER_ID,
      iat: now,
      exp: now + 15 * 60,
      aud: 'appstoreconnect-v1',
    })
  );
  const data = `${header}.${payload}`;
  const signer = createSign('SHA256');
  signer.update(data);
  signer.end();
  const signature = signer
    .sign({ key: PRIVATE_KEY, dsaEncoding: 'ieee-p1363' })
    .toString('base64')
    .replace(/=/g, '')
    .replace(/\+/g, '-')
    .replace(/\//g, '_');
  return `${data}.${signature}`;
}

async function asc(path, init = {}) {
  const url = path.startsWith('http') ? path : `https://api.appstoreconnect.apple.com${path}`;
  const res = await fetch(url, {
    ...init,
    headers: {
      Authorization: `Bearer ${makeToken()}`,
      'Content-Type': 'application/json',
      ...(init.headers || {}),
    },
  });
  if (!res.ok) {
    const body = await res.text();
    throw new Error(`ASC ${init.method || 'GET'} ${path} failed: ${res.status} ${body}`);
  }
  if (res.status === 204) return null;
  return res.json();
}

async function findBuild() {
  const params = new URLSearchParams({
    'filter[app]': APP_ID,
    'filter[preReleaseVersion.version]': VERSION,
    'filter[version]': BUILD_NUMBER,
    'fields[builds]': 'version,processingState,uploadedDate',
    limit: '1',
  });
  const data = await asc(`/v1/builds?${params}`);
  return data?.data?.[0] || null;
}

async function findGroup() {
  const params = new URLSearchParams({
    'filter[app]': APP_ID,
    'filter[name]': GROUP_NAME,
    limit: '1',
  });
  const data = await asc(`/v1/betaGroups?${params}`);
  const group = data?.data?.[0];
  if (!group) {
    throw new Error(`No beta group named "${GROUP_NAME}" found on app ${APP_ID}`);
  }
  return group;
}

async function attachBuild(groupId, buildId) {
  return asc(`/v1/betaGroups/${groupId}/relationships/builds`, {
    method: 'POST',
    body: JSON.stringify({ data: [{ type: 'builds', id: buildId }] }),
  });
}

async function waitForProcessed() {
  const deadline = Date.now() + POLL_TIMEOUT_MINUTES * 60 * 1000;
  let lastState = null;
  while (Date.now() < deadline) {
    const build = await findBuild();
    if (build) {
      lastState = build.attributes.processingState;
      if (lastState === 'VALID') {
        return build;
      }
      if (lastState === 'FAILED' || lastState === 'INVALID') {
        throw new Error(`Build ${BUILD_NUMBER} processing state: ${lastState}`);
      }
    }
    console.log(
      `Waiting for build ${BUILD_NUMBER} (state: ${lastState || 'not found yet'})…`
    );
    await new Promise((r) => setTimeout(r, POLL_INTERVAL_SECONDS * 1000));
  }
  throw new Error(`Timed out waiting for build ${BUILD_NUMBER} to finish processing`);
}

async function main() {
  console.log(`Attaching build ${VERSION} (${BUILD_NUMBER}) to "${GROUP_NAME}"`);
  const [build, group] = await Promise.all([waitForProcessed(), findGroup()]);
  await attachBuild(group.id, build.id);
  console.log(
    `Attached build ${build.id} to group ${group.id} ("${group.attributes.name}")`
  );
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
