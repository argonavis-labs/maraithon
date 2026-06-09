#!/usr/bin/env node
// Adds the just-uploaded TestFlight build to beta tester groups via the
// App Store Connect API.
//
// Required env:
//   ASC_KEY_ID              App Store Connect API key ID
//   ASC_ISSUER_ID           App Store Connect API issuer ID
//   ASC_PRIVATE_KEY         The .p8 private key contents (PEM, multi-line)
//   ASC_APP_ID              App Store Connect numeric app ID
//   ASC_VERSION_STRING      Marketing version (e.g. "1.0")
//   ASC_BUILD_NUMBER        Build number to match (e.g. "202606090100")
//   TESTFLIGHT_GROUP_NAMES  Comma-separated beta group display names
//                           (e.g. "Internal Testers")
//                           TESTFLIGHT_GROUP_NAME is accepted as a legacy fallback.
//
// Optional env:
//   OPTIONAL_TESTFLIGHT_GROUP_NAMES  Comma-separated beta groups to attach when
//                                    they exist. Missing optional groups are skipped.
//   REQUIRED_TESTER_EMAILS           Comma-separated emails that must be present
//                                    in every required TestFlight group.
//                                    REQUIRED_INTERNAL_TESTER_EMAILS is accepted
//                                    as a legacy fallback.
//
// Polls until the build is processed, then attaches it to the group.

import { createSign } from 'node:crypto';

const REQUIRED = [
  'ASC_KEY_ID',
  'ASC_ISSUER_ID',
  'ASC_PRIVATE_KEY',
  'ASC_APP_ID',
  'ASC_VERSION_STRING',
  'ASC_BUILD_NUMBER',
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
const GROUP_NAMES = parseList(
  process.env.TESTFLIGHT_GROUP_NAMES || process.env.TESTFLIGHT_GROUP_NAME
);
const OPTIONAL_GROUP_NAMES = parseList(process.env.OPTIONAL_TESTFLIGHT_GROUP_NAMES);
const REQUIRED_TESTER_EMAILS = parseList(
  process.env.REQUIRED_TESTER_EMAILS || process.env.REQUIRED_INTERNAL_TESTER_EMAILS
).map((email) => email.toLowerCase());

const POLL_INTERVAL_SECONDS = Number(process.env.ASC_POLL_INTERVAL_SECONDS || 60);
const POLL_TIMEOUT_MINUTES = Number(process.env.ASC_POLL_TIMEOUT_MINUTES || 45);

if (GROUP_NAMES.length === 0) {
  console.error('Missing required env: TESTFLIGHT_GROUP_NAMES');
  process.exit(1);
}

const GROUP_REQUESTS = [
  ...GROUP_NAMES.map((name) => ({ name, required: true })),
  ...OPTIONAL_GROUP_NAMES.filter((name) => !GROUP_NAMES.includes(name)).map(
    (name) => ({ name, required: false })
  ),
];

function parseList(value) {
  return [
    ...new Set(
      String(value || '')
        .split(',')
        .map((item) => item.trim())
        .filter(Boolean)
    ),
  ];
}

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
  const { allowConflict = false, ...fetchInit } = init;
  const url = path.startsWith('http') ? path : `https://api.appstoreconnect.apple.com${path}`;
  const res = await fetch(url, {
    ...fetchInit,
    headers: {
      Authorization: `Bearer ${makeToken()}`,
      'Content-Type': 'application/json',
      ...(fetchInit.headers || {}),
    },
  });
  if (allowConflict && res.status === 409) {
    const body = await res.text();
    return { conflict: true, body };
  }
  if (!res.ok) {
    const body = await res.text();
    throw new Error(`ASC ${fetchInit.method || 'GET'} ${path} failed: ${res.status} ${body}`);
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

async function findGroup(groupName, required = true) {
  const params = new URLSearchParams({
    'filter[app]': APP_ID,
    'filter[name]': groupName,
    'fields[betaGroups]': 'name,isInternalGroup,hasAccessToAllBuilds',
    limit: '1',
  });
  const data = await asc(`/v1/betaGroups?${params}`);
  const group = data?.data?.[0];
  if (!group) {
    if (!required) {
      console.log(`Optional beta group "${groupName}" was not found; skipping`);
      return null;
    }
    throw new Error(`No beta group named "${groupName}" found on app ${APP_ID}`);
  }
  return group;
}

async function attachBuild(groupId, buildId) {
  const result = await asc(`/v1/betaGroups/${groupId}/relationships/builds`, {
    method: 'POST',
    allowConflict: true,
    body: JSON.stringify({ data: [{ type: 'builds', id: buildId }] }),
  });
  return result?.conflict ? 'already-attached' : 'attached';
}

async function listBetaTestersForGroup(groupId) {
  let path = `/v1/betaGroups/${groupId}/betaTesters?fields[betaTesters]=email,firstName,lastName&limit=200`;
  const testers = [];

  while (path) {
    const data = await asc(path);
    testers.push(...(data?.data || []));
    const next = data?.links?.next;
    path = next ? next.replace('https://api.appstoreconnect.apple.com', '') : null;
  }

  return testers;
}

async function verifyRequiredTesters(group, required) {
  if (!required || REQUIRED_TESTER_EMAILS.length === 0) {
    return;
  }

  const testers = await listBetaTestersForGroup(group.id);
  const presentEmails = new Set(
    testers
      .map((tester) => tester.attributes?.email?.toLowerCase())
      .filter(Boolean)
  );
  const missing = REQUIRED_TESTER_EMAILS.filter((email) => !presentEmails.has(email));

  if (missing.length > 0) {
    throw new Error(
      `Required TestFlight group "${group.attributes.name}" is missing tester email(s): ${missing.join(
        ', '
      )}. Add them in App Store Connect → TestFlight → Internal Testing.`
    );
  }

  console.log(
    `Verified "${group.attributes.name}" includes ${REQUIRED_TESTER_EMAILS.join(', ')}`
  );
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
  console.log(
    `Attaching build ${VERSION} (${BUILD_NUMBER}) to ${GROUP_REQUESTS.map((group) => group.required ? `"${group.name}"` : `"${group.name}" (optional)`).join(', ')}`
  );
  const [build, groups] = await Promise.all([
    waitForProcessed(),
    Promise.all(
      GROUP_REQUESTS.map((group) => findGroup(group.name, group.required))
    ),
  ]);

  for (const group of groups.filter(Boolean)) {
    const request = GROUP_REQUESTS.find((item) => item.name === group.attributes.name);
    const required = request?.required ?? true;
    await verifyRequiredTesters(group, required);
    if (group.attributes?.hasAccessToAllBuilds) {
      console.log(
        `Group ${group.id} ("${group.attributes.name}") already has access to all builds`
      );
      continue;
    }

    const result = await attachBuild(group.id, build.id);
    if (result === 'already-attached') {
      console.log(
        `Build ${build.id} was already attached to group ${group.id} ("${group.attributes.name}")`
      );
    } else {
      console.log(
        `Attached build ${build.id} to group ${group.id} ("${group.attributes.name}")`
      );
    }
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
