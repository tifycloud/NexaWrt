#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

class FakeClassList {
  constructor() { this.values = new Set(); }
  add(...names) { for (const name of names) this.values.add(name); }
  remove(...names) { for (const name of names) this.values.delete(name); }
  contains(name) { return this.values.has(name); }
}

class FakeElement {
  constructor(tagName = 'div') {
    this.tagName = tagName;
    this.textContent = '';
    this.className = '';
    this.classList = new FakeClassList();
    this.hidden = false;
    this.children = [];
    this.dateTime = '';
    this.href = undefined;
    this.target = '';
    this.rel = '';
    this.fields = new Map();
  }
  querySelector(selector) { return this.fields.get(selector) || null; }
  replaceChildren(...children) {
    this.children = children.flatMap((child) => child?.tagName === '#fragment' ? child.children : [child]);
  }
  append(...children) { this.children.push(...children); }
  removeAttribute(name) { if (name === 'href') this.href = undefined; }
}

function makeCard() {
  const card = new FakeElement('article');
  for (const [selector, tag] of [
    ['[data-field="version"]', 'strong'],
    ['[data-field="date"]', 'time'],
    ['[data-field="downloads"]', 'div'],
    ['[data-field="provenance"]', 'div'],
    ['[data-field="support-links"]', 'div'],
    ['[data-field="release-url"]', 'a'],
    ['details', 'details'],
  ]) card.fields.set(selector, new FakeElement(tag));
  card.querySelector('[data-field="release-url"]').hidden = true;
  card.querySelector('details').hidden = true;
  return card;
}

function makeDom() {
  const selectors = new Map();
  selectors.set('[data-device-field="name"]', new FakeElement('dd'));
  selectors.set('[data-device-field="target"]', new FakeElement('dd'));
  selectors.set('[data-device-field="status"]', new FakeElement('dd'));
  selectors.set('#browser-build-link', new FakeElement('a'));
  selectors.get('#browser-build-link').hidden = true;
  selectors.set('#device-doc-links', new FakeElement('div'));
  selectors.set('#release-history', new FakeElement('div'));
  selectors.set('#data-status', new FakeElement('p'));
  selectors.set('[data-flavor="official"]', makeCard());
  selectors.set('[data-flavor="nss"]', makeCard());
  return {
    selectors,
    querySelector(selector) { return selectors.get(selector) || null; },
    createElement(tagName) { return new FakeElement(tagName); },
    createDocumentFragment() { return new FakeElement('#fragment'); },
  };
}

const root = path.resolve(__dirname, '..');
const source = fs.readFileSync(path.join(root, 'site/app.js'), 'utf8');
const testedSource = source.split('\nconst TIMEZONES =', 1)[0] +
  '\nglobalThis.hooks = { validDevice, validRelease, validReleaseGroup, validUtcTimestamp, compareVersions, loadReleases };\n';
const document = makeDom();
const loggedErrors = [];
const context = vm.createContext({
  URL, Date, Set, JSON, Number, Intl,
  document,
  fetch: async () => { throw new Error('fetch stub not configured'); },
  console: { error: (...args) => loggedErrors.push(args) },
});
vm.runInContext(testedSource, context, { filename: 'site/app.js' });
const { validDevice, validRelease, validReleaseGroup, validUtcTimestamp, compareVersions, loadReleases } = context.hooks;
const clone = (value) => JSON.parse(JSON.stringify(value));

const index = JSON.parse(fs.readFileSync(path.join(root, 'site/releases.json'), 'utf8'));
const device = index.devices['xiaomi-ax9000'];
assert.equal(validDevice(device), true);
assert.equal(validUtcTimestamp(index.generated_at), true);
assert.equal(compareVersions('v1.10.0-rc.1', 'v1.9.0-rc.1') > 0, true);

function makeRelease(flavor, version, publishedAt) {
  const tag = flavor === 'nss' ? `ram-test-nss-${version}` : `ram-test-${version}`;
  const archive = `NexaWrt-AX9000-${flavor}-${version}-verified-dist.tar.gz`;
  const asset = (name) => ({
    name,
    size: 1,
    url: `https://github.com/tifycloud/NexaWrt/releases/download/${tag}/${name}`,
  });
  return {
    device_id: device.id,
    device_name: device.display_name,
    flavor,
    flavor_experimental: flavor === 'nss',
    channel: 'ram-test',
    hardware_status: 'unverified',
    production_ready: false,
    ram_only: true,
    version,
    tag,
    published_at: publishedAt,
    release_url: `https://github.com/tifycloud/NexaWrt/releases/tag/${tag}`,
    browser_build_workflow_url: device.browser_build_workflow_url,
    recovery_url: device.recovery_url,
    testing_url: device.testing_url,
    assets: {
      archive: asset(archive),
      checksum: asset(`${archive}.sha256`),
      provenance_archive: asset('archive.provenance.bundle.json'),
      provenance_checksums: asset('checksums.provenance.bundle.json'),
      provenance_firmware: asset('firmware.provenance.bundle.json'),
      provenance_sbom: asset('sbom.provenance.bundle.json'),
    },
  };
}

const release = makeRelease('official', 'v1.2.3-rc.4', '2026-07-17T12:34:56Z');
assert.equal(validRelease(release, 'official', device), true);
assert.equal(validReleaseGroup({ latest: release, history: [release] }, 'official', device), true);

for (const mutate of [
  (value) => { value.production_ready = true; },
  (value) => { value.ram_only = false; },
  (value) => { value.published_at = '2026-07-17 12:34:56'; },
  (value) => { value.release_url = 'https://attacker.invalid/release'; },
  (value) => { value.assets.archive.url = 'https://attacker.invalid/archive'; },
  (value) => { value.assets.archive.size = 0; },
  (value) => { value.assets.extra = { name: 'openwrt-sysupgrade.bin', size: 1, url: 'https://attacker.invalid' }; },
]) {
  const invalid = clone(release);
  mutate(invalid);
  assert.equal(validRelease(invalid, 'official', device), false);
}

for (const mutate of [
  (value) => { value.production_ready = true; },
  (value) => { value.hardware_status = 'verified'; },
  (value) => { value.image_capabilities.sysupgrade = true; },
  (value) => { value.browser_build_workflow_url = 'https://attacker.invalid/build'; },
]) {
  const invalid = clone(device);
  mutate(invalid);
  assert.equal(validDevice(invalid), false);
}

const newer = makeRelease('official', 'v1.2.4-rc.1', '2026-07-18T00:00:00Z');
assert.equal(validReleaseGroup({ latest: newer, history: [newer, release] }, 'official', device), true);
assert.equal(validReleaseGroup({ latest: release, history: [newer, release] }, 'official', device), false);
assert.equal(validReleaseGroup({ latest: release, history: [release, newer] }, 'official', device), false);
assert.equal(validReleaseGroup({ latest: release, history: [release, release] }, 'official', device), false);
assert.equal(validReleaseGroup({ latest: null, history: [] }, 'official', device), true);
assert.equal(validReleaseGroup({ latest: release, history: [] }, 'official', device), false);

const sameTimeHigh = makeRelease('official', 'v1.10.0-rc.1', '2026-07-18T01:00:00Z');
const sameTimeLow = makeRelease('official', 'v1.9.0-rc.1', '2026-07-18T01:00:00Z');
assert.equal(validReleaseGroup({ latest: sameTimeHigh, history: [sameTimeHigh, sameTimeLow] }, 'official', device), true);
assert.equal(validReleaseGroup({ latest: sameTimeLow, history: [sameTimeLow, sameTimeHigh] }, 'official', device), false);

const hugeHigh = makeRelease('official', 'v9007199254740993.0.0-rc.1', '2026-07-18T01:00:00Z');
const hugeLow = makeRelease('official', 'v9007199254740992.0.0-rc.1', '2026-07-18T01:00:00Z');
assert.equal(compareVersions(hugeHigh.version, hugeLow.version), 1);
assert.equal(validReleaseGroup({ latest: hugeHigh, history: [hugeHigh, hugeLow] }, 'official', device), true);
assert.equal(validReleaseGroup({ latest: hugeLow, history: [hugeLow, hugeHigh] }, 'official', device), false);

const official = makeRelease('official', 'v2.0.0-rc.1', '2026-07-18T02:00:00Z');
const nss = makeRelease('nss', 'v2.0.0-rc.1', '2026-07-18T02:00:00Z');
const validIndex = {
  schema_version: 2,
  repository: 'tifycloud/NexaWrt',
  generated_at: '2026-07-18T02:01:00Z',
  devices: { 'xiaomi-ax9000': clone(device) },
  flavors: {
    official: { latest: official, history: [official] },
    nss: { latest: nss, history: [nss] },
  },
};

async function loadWith(responseFactory) {
  context.fetch = responseFactory;
  await loadReleases();
}

function card(flavor) { return document.querySelector(`[data-flavor="${flavor}"]`); }
function assertSafeEmptyState() {
  const build = document.querySelector('#browser-build-link');
  const officialCard = card('official');
  assert.equal(build.hidden, true);
  assert.equal(build.href, undefined);
  assert.equal(document.querySelector('#device-doc-links').children.length, 0);
  assert.equal(officialCard.querySelector('[data-field="downloads"]').children.some((child) => child.tagName === 'a'), false);
  assert.equal(officialCard.querySelector('[data-field="provenance"]').children.length, 0);
  assert.equal(officialCard.querySelector('[data-field="support-links"]').children.length, 0);
  assert.equal(officialCard.querySelector('[data-field="release-url"]').hidden, true);
  assert.equal(officialCard.querySelector('[data-field="release-url"]').href, undefined);
  assert.equal(officialCard.querySelector('details').hidden, true);
  assert.equal(document.querySelector('#release-history').children.some((child) => child.tagName === 'article'), false);
  assert.equal(document.querySelector('#data-status').classList.contains('error'), true);
}

(async () => {
  await loadWith(async () => ({ ok: true, json: async () => clone(validIndex) }));
  assert.equal(document.querySelector('#browser-build-link').hidden, false);
  assert.equal(document.querySelector('#browser-build-link').href, device.browser_build_workflow_url);
  assert.equal(document.querySelector('#device-doc-links').children.length, 2);
  assert.equal(card('official').querySelector('[data-field="downloads"]').children[0].href, official.assets.archive.url);
  assert.equal(card('official').querySelector('[data-field="provenance"]').children.length, 4);
  assert.equal(card('official').querySelector('[data-field="release-url"]').href, official.release_url);
  assert.equal(card('official').querySelector('details').hidden, false);

  const partialFailure = clone(validIndex);
  partialFailure.flavors.nss.latest.production_ready = true;
  partialFailure.flavors.nss.history[0].production_ready = true;
  await loadWith(async () => ({ ok: true, json: async () => partialFailure }));
  assertSafeEmptyState();

  await loadWith(async () => ({ ok: true, json: async () => ({ schema_version: 999 }) }));
  assertSafeEmptyState();

  await loadWith(async () => ({ ok: true, json: async () => { throw new SyntaxError('bad json'); } }));
  assertSafeEmptyState();

  await loadWith(async () => ({ ok: false, status: 503, json: async () => ({}) }));
  assertSafeEmptyState();

  await loadWith(async () => { throw new Error('network down'); });
  assertSafeEmptyState();
  assert.equal(loggedErrors.length >= 5, true);

  console.log('Pages UI policy: validators, semantic ordering, and load failures fail closed');
})().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
