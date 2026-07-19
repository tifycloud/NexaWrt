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
    this.value = '';
    this.disabled = false;
    this.attributes = new Map();
    this.fields = new Map();
    this.listeners = new Map();
  }
  querySelector(selector) { return this.fields.get(selector) || null; }
  replaceChildren(...children) {
    this.children = children.flatMap((child) => child?.tagName === '#fragment' ? child.children : [child]);
  }
  append(...children) { this.children.push(...children); }
  addEventListener(type, listener) {
    const listeners = this.listeners.get(type) || [];
    listeners.push(listener);
    this.listeners.set(type, listeners);
  }
  dispatchEvent(event) {
    event.currentTarget = this;
    for (const listener of this.listeners.get(event.type) || []) listener.call(this, event);
  }
  setAttribute(name, value) { this.attributes.set(name, String(value)); }
  getAttribute(name) { return this.attributes.has(name) ? this.attributes.get(name) : null; }
  removeAttribute(name) {
    this.attributes.delete(name);
    if (name === 'href') this.href = undefined;
  }
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

function makeVmCard() {
  const card = new FakeElement('article');
  for (const [selector, tag] of [
    ['[data-vm-field="version"]', 'strong'],
    ['[data-vm-field="date"]', 'time'],
    ['[data-vm-field="downloads"]', 'div'],
    ['[data-vm-field="provenance"]', 'div'],
    ['[data-vm-field="support-links"]', 'div'],
    ['[data-vm-field="release-url"]', 'a'],
    ['details', 'details'],
  ]) card.fields.set(selector, new FakeElement(tag));
  card.querySelector('[data-vm-field="release-url"]').hidden = true;
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
  selectors.set('#vm-history', new FakeElement('div'));
  selectors.set('#vm-history-actions', new FakeElement('div'));
  selectors.get('#vm-history-actions').hidden = true;
  selectors.set('[data-vm-platform="x86_64"]', makeVmCard());
  selectors.set('#data-status', new FakeElement('p'));
  const configForm = new FakeElement('form');
  configForm.elements = {
    hostname: new FakeElement('input'),
    'lan-ip': new FakeElement('input'),
    timezone: new FakeElement('select'),
    country: new FakeElement('select'),
  };
  configForm.elements.hostname.value = 'nexawrt-ax9000';
  configForm.elements['lan-ip'].value = '192.168.8.1';
  configForm.elements.timezone.value = 'Asia/Shanghai';
  configForm.elements.country.value = 'CN';
  selectors.set('#config-form', configForm);
  selectors.set('#config-error', new FakeElement('p'));
  selectors.get('#config-error').hidden = true;
  selectors.set('#config-output', new FakeElement('code'));
  selectors.get('#config-output').textContent = '# initial placeholder';
  selectors.set('#copy-snippet', new FakeElement('button'));
  selectors.get('#copy-snippet').disabled = true;
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
const testedSource = source.replace(/\nloadReleases\(\);\s*$/, '\n') +
  '\nglobalThis.hooks = { validDevice, validRelease, validReleaseGroup, validVmRelease, validVmReleaseGroup, validUtcTimestamp, compareVersions, loadReleases, generateSnippet };\n';
const document = makeDom();
const loggedErrors = [];
const context = vm.createContext({
  URL, Date, Set, JSON, Number, Intl,
  document,
  fetch: async () => { throw new Error('fetch stub not configured'); },
  console: { error: (...args) => loggedErrors.push(args) },
});
vm.runInContext(testedSource, context, { filename: 'site/app.js' });
const { validDevice, validRelease, validReleaseGroup, validVmRelease, validVmReleaseGroup, validUtcTimestamp, compareVersions, loadReleases, generateSnippet } = context.hooks;
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

function makeVmRelease(version, publishedAt) {
  const tag = `vm-x86_64-${version}`;
  const image = `NexaWrt-x86_64-${version}-generic-ext4-combined.img.gz`;
  const asset = (name) => ({
    name,
    size: 1,
    url: `https://github.com/tifycloud/NexaWrt/releases/download/${tag}/${name}`,
  });
  return {
    platform: 'x86_64',
    artifact_class: 'VM_DISTRIBUTION_IMAGE',
    vm_only: true,
    not_ax9000_firmware: true,
    hardware_validation: false,
    nss_validation: false,
    qemu_validated: true,
    ssh_default: 'disabled',
    version,
    tag,
    published_at: publishedAt,
    release_url: `https://github.com/tifycloud/NexaWrt/releases/tag/${tag}`,
    browser_build_workflow_url: 'https://github.com/tifycloud/NexaWrt/actions/workflows/vm-release.yml',
    docs_url: 'https://github.com/tifycloud/NexaWrt/blob/main/docs/VM-X86_64.md',
    assets: {
      image: asset(image),
      image_checksum: asset(`${image}.sha256`),
      manifest: asset(`${image.slice(0, -'.img.gz'.length)}.manifest`),
      artifact_labels: asset('artifact-labels.env'),
      readme: asset('README-VM.txt'),
      smoke_report: asset('smoke-report.txt'),
      checksums: asset('SHA256SUMS'),
      provenance_image: asset('image.provenance.bundle.json'),
      provenance_checksums: asset('checksums.provenance.bundle.json'),
    },
  };
}

const release = makeRelease('official', 'v1.2.3-rc.4', '2026-07-17T12:34:56Z');
assert.equal(validRelease(release, 'official', device), true);
assert.equal(validReleaseGroup({ latest: release, history: [release] }, 'official', device), true);
const vmRelease = makeVmRelease('v0.1.0-rc.1', '2026-07-18T02:00:00Z');
assert.equal(validVmRelease(vmRelease), true);
assert.equal(validVmReleaseGroup({ latest: vmRelease, history: [vmRelease] }), true);
for (const mutate of [
  (value) => { value.vm_only = false; },
  (value) => { value.not_ax9000_firmware = false; },
  (value) => { value.hardware_validation = true; },
  (value) => { value.ssh_default = 'enabled'; },
  (value) => { value.assets.image.url = 'https://attacker.invalid/image'; },
]) {
  const invalid = clone(vmRelease);
  mutate(invalid);
  assert.equal(validVmRelease(invalid), false);
}

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
  schema_version: 3,
  repository: 'tifycloud/NexaWrt',
  generated_at: '2026-07-18T02:01:00Z',
  devices: { 'xiaomi-ax9000': clone(device) },
  flavors: {
    official: { latest: official, history: [official] },
    nss: { latest: nss, history: [nss] },
  },
  virtual_images: { x86_64: { latest: vmRelease, history: [vmRelease] } },
};

async function loadWith(responseFactory) {
  context.fetch = responseFactory;
  await loadReleases();
}

function card(flavor) { return document.querySelector(`[data-flavor="${flavor}"]`); }
function dispatchConfigEvent(type) {
  document.querySelector('#config-form').dispatchEvent({
    type,
    preventDefault() {},
  });
}
function submitConfig() { dispatchConfigEvent('submit'); }
function assertNoInvalidFields() {
  const fields = document.querySelector('#config-form').elements;
  for (const name of ['hostname', 'lan-ip', 'timezone', 'country']) {
    assert.equal(fields[name].getAttribute('aria-invalid'), null);
  }
}
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
  const vmCard = document.querySelector('[data-vm-platform="x86_64"]');
  assert.equal(vmCard.querySelector('[data-vm-field="downloads"]').children.some((child) => child.tagName === 'a'), false);
  assert.equal(vmCard.querySelector('[data-vm-field="provenance"]').children.length, 0);
  assert.equal(vmCard.querySelector('[data-vm-field="support-links"]').children.length, 0);
  assert.equal(vmCard.querySelector('[data-vm-field="release-url"]').hidden, true);
  assert.equal(vmCard.querySelector('[data-vm-field="release-url"]').href, undefined);
  assert.equal(vmCard.querySelector('details').hidden, true);
  const vmHistoryActions = document.querySelector('#vm-history-actions');
  assert.equal(vmHistoryActions.hidden, true);
  assert.equal(vmHistoryActions.children.length, 0);
  assert.equal(document.querySelector('#vm-history').children.some((child) => child.tagName === 'article'), false);
  assert.equal(document.querySelector('#data-status').classList.contains('error'), true);
}

(async () => {
  const configForm = document.querySelector('#config-form');
  const configOutput = document.querySelector('#config-output');
  const configError = document.querySelector('#config-error');
  const copyButton = document.querySelector('#copy-snippet');

  submitConfig();
  const validSnippet = configOutput.textContent;
  assert.match(validSnippet, /set network\.lan\.ipaddr='192\.168\.8\.1'/);
  assert.equal(copyButton.disabled, false);
  assert.equal(configError.hidden, true);
  assertNoInvalidFields();

  configForm.elements['lan-ip'].value = '8.8.8.8';
  dispatchConfigEvent('input');
  assert.equal(configOutput.textContent, '# 配置尚未通过验证 / Configuration not validated');
  assert.equal(configOutput.textContent.includes(validSnippet), false);
  assert.equal(copyButton.disabled, true);
  assert.equal(configError.hidden, true);
  assert.equal(configError.textContent, '');
  assertNoInvalidFields();

  submitConfig();
  assert.equal(configOutput.textContent, '# 配置尚未通过验证 / Configuration not validated');
  assert.equal(copyButton.disabled, true);
  assert.equal(configError.hidden, false);
  assert.match(configError.textContent, /LAN IP/);
  assert.equal(configForm.elements['lan-ip'].getAttribute('aria-invalid'), 'true');
  assert.equal(configForm.elements.hostname.getAttribute('aria-invalid'), null);
  assert.equal(configForm.elements.timezone.getAttribute('aria-invalid'), null);
  assert.equal(configForm.elements.country.getAttribute('aria-invalid'), null);

  configForm.elements['lan-ip'].value = '10.0.0.1';
  dispatchConfigEvent('change');
  assert.equal(configOutput.textContent, '# 配置尚未通过验证 / Configuration not validated');
  assert.equal(copyButton.disabled, true);
  assert.equal(configError.hidden, true);
  assert.equal(configError.textContent, '');
  assertNoInvalidFields();

  submitConfig();
  assert.match(configOutput.textContent, /set network\.lan\.ipaddr='10\.0\.0\.1'/);
  assert.notEqual(configOutput.textContent, validSnippet);
  assert.equal(copyButton.disabled, false);
  assert.equal(configError.hidden, true);
  assertNoInvalidFields();

  await loadWith(async () => ({ ok: true, json: async () => clone(validIndex) }));
  assert.equal(document.querySelector('#browser-build-link').hidden, false);
  assert.equal(document.querySelector('#browser-build-link').href, device.browser_build_workflow_url);
  assert.equal(document.querySelector('#device-doc-links').children.length, 2);
  assert.equal(card('official').querySelector('[data-field="downloads"]').children[0].href, official.assets.archive.url);
  assert.equal(card('official').querySelector('[data-field="provenance"]').children.length, 4);
  assert.equal(card('official').querySelector('[data-field="release-url"]').href, official.release_url);
  assert.equal(card('official').querySelector('details').hidden, false);
  const vmCard = document.querySelector('[data-vm-platform="x86_64"]');
  assert.equal(vmCard.querySelector('[data-vm-field="downloads"]').children[0].href, vmRelease.assets.image.url);
  assert.equal(vmCard.querySelector('[data-vm-field="provenance"]').children.length, 2);
  assert.equal(vmCard.querySelector('[data-vm-field="release-url"]').href, vmRelease.release_url);
  assert.equal(vmCard.querySelector('[data-vm-field="support-links"]').children[0].href, vmRelease.browser_build_workflow_url);
  assert.equal(vmCard.querySelector('[data-vm-field="support-links"]').children.length, 2);
  assert.equal(vmCard.querySelector('details').hidden, false);
  const vmHistoryActions = document.querySelector('#vm-history-actions');
  assert.equal(vmHistoryActions.hidden, false);
  assert.equal(vmHistoryActions.children.length, 1);
  assert.equal(vmHistoryActions.children[0].href, vmRelease.browser_build_workflow_url);

  const invalidVmOnly = clone(validIndex);
  invalidVmOnly.virtual_images.x86_64.latest.hardware_validation = true;
  invalidVmOnly.virtual_images.x86_64.history[0].hardware_validation = true;
  await loadWith(async () => ({ ok: true, json: async () => invalidVmOnly }));
  assert.equal(document.querySelector('#browser-build-link').hidden, false);
  assert.equal(card('official').querySelector('[data-field="downloads"]').children[0].href, official.assets.archive.url);
  const invalidVmCard = document.querySelector('[data-vm-platform="x86_64"]');
  assert.equal(invalidVmCard.querySelector('[data-vm-field="downloads"]').children.some((child) => child.tagName === 'a'), false);
  assert.equal(invalidVmCard.querySelector('[data-vm-field="provenance"]').children.length, 0);
  assert.equal(invalidVmCard.querySelector('[data-vm-field="support-links"]').children.length, 0);
  assert.equal(invalidVmCard.querySelector('[data-vm-field="release-url"]').hidden, true);
  assert.equal(invalidVmCard.querySelector('[data-vm-field="release-url"]').href, undefined);
  assert.equal(invalidVmCard.querySelector('details').hidden, true);
  assert.equal(document.querySelector('#vm-history-actions').hidden, true);
  assert.equal(document.querySelector('#vm-history-actions').children.length, 0);
  assert.equal(document.querySelector('#vm-history').children.some((child) => child.tagName === 'article'), false);

  const invalidAxOnly = clone(validIndex);
  invalidAxOnly.flavors.nss.latest.production_ready = true;
  invalidAxOnly.flavors.nss.history[0].production_ready = true;
  await loadWith(async () => ({ ok: true, json: async () => invalidAxOnly }));
  assert.equal(document.querySelector('#browser-build-link').hidden, true);
  assert.equal(card('official').querySelector('[data-field="release-url"]').hidden, true);
  const validVmCardWithInvalidAx = document.querySelector('[data-vm-platform="x86_64"]');
  assert.equal(validVmCardWithInvalidAx.querySelector('[data-vm-field="downloads"]').children[0].href, vmRelease.assets.image.url);
  assert.equal(validVmCardWithInvalidAx.querySelector('[data-vm-field="support-links"]').children[0].href, vmRelease.browser_build_workflow_url);
  assert.equal(validVmCardWithInvalidAx.querySelector('[data-vm-field="release-url"]').hidden, false);
  assert.equal(document.querySelector('#vm-history-actions').hidden, false);
  assert.equal(document.querySelector('#vm-history-actions').children[0].href, vmRelease.browser_build_workflow_url);
  assert.equal(document.querySelector('#data-status').classList.contains('error'), false);

  const invalidAxDeviceOnly = clone(validIndex);
  invalidAxDeviceOnly.devices['xiaomi-ax9000'].production_ready = true;
  await loadWith(async () => ({ ok: true, json: async () => invalidAxDeviceOnly }));
  assert.equal(document.querySelector('#browser-build-link').hidden, true);
  assert.equal(document.querySelector('[data-vm-platform="x86_64"]').querySelector('[data-vm-field="release-url"]').href, vmRelease.release_url);
  assert.equal(document.querySelector('[data-vm-platform="x86_64"]').querySelector('[data-vm-field="support-links"]').children[0].href, vmRelease.browser_build_workflow_url);
  assert.equal(document.querySelector('#vm-history-actions').children[0].href, vmRelease.browser_build_workflow_url);

  await loadWith(async () => ({ ok: true, json: async () => ({ schema_version: 999 }) }));
  assertSafeEmptyState();

  await loadWith(async () => ({ ok: true, json: async () => { throw new SyntaxError('bad json'); } }));
  assertSafeEmptyState();

  await loadWith(async () => ({ ok: false, status: 503, json: async () => ({}) }));
  assertSafeEmptyState();

  await loadWith(async () => { throw new Error('network down'); });
  assertSafeEmptyState();
  assert.equal(loggedErrors.length >= 5, true);

  console.log('Pages UI policy: bidirectional AX9000/VM isolation, edits invalidate stale config, and top-level failures close both');
})().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
