#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { webcrypto } = require('node:crypto');
const { TextEncoder } = require('node:util');
const { execFileSync } = require('node:child_process');

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
    this.checked = false;
    this.selected = false;
    this.type = '';
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
  selectors.set('#component-status', new FakeElement('p'));
  for (const selector of ['#component-target', '#component-flavor', '#component-category', '#component-source', '#component-risk', '#component-feed']) {
    selectors.set(selector, new FakeElement('select'));
    selectors.get(selector).disabled = true;
  }
  selectors.set('#component-search', new FakeElement('input'));
  selectors.set('#component-package-status', new FakeElement('p'));
  selectors.set('#component-result-status', new FakeElement('p'));
  selectors.set('#component-error', new FakeElement('p'));
  selectors.get('#component-error').hidden = true;
  selectors.set('#component-selected-official', new FakeElement('div'));
  selectors.set('#component-list', new FakeElement('div'));
  selectors.set('#component-packages', new FakeElement('pre'));
  selectors.set('#component-normalized', new FakeElement('code'));
  selectors.set('#component-request-hash', new FakeElement('code'));
  selectors.set('#component-actions-inputs', new FakeElement('code'));
  selectors.set('#copy-actions-inputs', new FakeElement('button'));
  selectors.get('#copy-actions-inputs').disabled = true;
  selectors.set('#custom-build-workflow-link', new FakeElement('a'));
  selectors.get('#custom-build-workflow-link').hidden = true;
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
const testedSource = source.replace(/\nloadReleases\(\);\nloadComponentCatalog\(\);\s*$/, '\n') +
  '\nglobalThis.hooks = { validDevice, validRelease, validReleaseGroup, validVmRelease, validVmReleaseGroup, validUtcTimestamp, compareVersions, loadReleases, generateSnippet, validateComponentCatalog, validatePackageCatalogRoot, validatePackagePurposeCatalog, validatePackageCatalogShard, validCommunityCandidateProjection, resolveComponentSelection, componentHashPayload, canonicalJson, sha256Hex, normalizedBuildRequest, actionsInputs, loadComponentCatalog, loadPackageShardForSelection, changeComponentSelection, renderComponentChoices, setCurrentPackageRecords: (records) => { currentPackageShard = { packages: records }; currentPackageMap = new Map(records.map((record) => [record.id, record])); currentPackageSearchTerms = packageSearchTerms(currentPackageShard); }, clearVerifiedPackageShardCache: () => verifiedPackageShardCache.clear(), getCurrentPackageRecords: () => [...currentPackageMap.values()], getRequestedComponentIds: () => [...requestedComponentIds], getResolvedComponentIds: () => [...resolvedComponentIds] };\n';
const document = makeDom();
const loggedErrors = [];
const context = vm.createContext({
  URL, Date, Set, Map, JSON, Number, Intl, Uint8Array, TextEncoder, setTimeout, clearTimeout, crypto: webcrypto,
  document,
  fetch: async () => { throw new Error('fetch stub not configured'); },
  console: { error: (...args) => loggedErrors.push(args) },
});
vm.runInContext(testedSource, context, { filename: 'site/app.js' });
const { validDevice, validRelease, validReleaseGroup, validVmRelease, validVmReleaseGroup, validUtcTimestamp, compareVersions, loadReleases, generateSnippet, validateComponentCatalog, validatePackageCatalogRoot, validatePackagePurposeCatalog, validatePackageCatalogShard, validCommunityCandidateProjection, resolveComponentSelection, componentHashPayload, canonicalJson, sha256Hex, normalizedBuildRequest, actionsInputs, loadComponentCatalog, loadPackageShardForSelection, changeComponentSelection, renderComponentChoices, setCurrentPackageRecords, clearVerifiedPackageShardCache, getCurrentPackageRecords, getRequestedComponentIds, getResolvedComponentIds } = context.hooks;
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


function makeVmReleaseV4(version, publishedAt, contractVersion) {
  const tag = `vm-x86_64-${version}`;
  const prefix = `NexaWrt-x86_64-${version}`;
  const raw = `${prefix}-generic-ext4-combined.img.gz`;
  const asset = (name) => ({
    name,
    size: 1,
    sha256: 'a'.repeat(64),
    url: `https://github.com/tifycloud/NexaWrt/releases/download/${tag}/${name}`,
  });
  let assets;
  let qemu;
  if (contractVersion === 1) {
    assets = {
      image: asset(raw),
      image_checksum: asset(`${raw}.sha256`),
      manifest: asset(`${prefix}-generic-ext4-combined.manifest`),
      artifact_labels: asset('artifact-labels.env'),
      readme: asset('README-VM.txt'),
      smoke_report: asset('smoke-report.txt'),
      checksums: asset('SHA256SUMS'),
      provenance_image: asset('image.provenance.bundle.json'),
      provenance_checksums: asset('checksums.provenance.bundle.json'),
    };
    qemu = { raw_bios: 'runtime-pass' };
  } else {
    const variants = {
      raw_bios: raw,
      iso_bios: `${prefix}-generic-image.iso`,
      iso_efi: `${prefix}-generic-image-efi.iso`,
      vmdk_bios: `${prefix}-generic-ext4-combined.vmdk`,
      vmdk_efi: `${prefix}-generic-ext4-combined-efi.vmdk`,
    };
    assets = {};
    for (const [key, name] of Object.entries(variants)) {
      assets[key] = asset(name);
      assets[`${key}_checksum`] = asset(`${name}.sha256`);
    }
    Object.assign(assets, {
      manifest: asset(`${prefix}-generic.manifest`),
      artifact_labels: asset('artifact-labels.env'),
      readme: asset('README-VM.txt'),
      smoke_report: asset('smoke-report.txt'),
      checksums: asset('SHA256SUMS'),
      provenance_raw_bios: asset('raw-bios.provenance.bundle.json'),
      provenance_iso_bios: asset('iso-bios.provenance.bundle.json'),
      provenance_iso_efi: asset('iso-efi.provenance.bundle.json'),
      provenance_vmdk_bios: asset('vmdk-bios.provenance.bundle.json'),
      provenance_vmdk_efi: asset('vmdk-efi.provenance.bundle.json'),
      provenance_checksums: asset('checksums.provenance.bundle.json'),
    });
    qemu = Object.fromEntries(Object.keys(variants).map((key) => [key, 'runtime-pass']));
  }
  return {
    platform: 'x86_64',
    artifact_class: contractVersion === 1 ? 'VM_DISTRIBUTION_IMAGE' : 'VM_DISTRIBUTION_SET',
    contract_version: contractVersion,
    release_contract: `vm-x86_64/v${contractVersion}`,
    vm_only: true,
    not_ax9000_firmware: true,
    hardware_validation: false,
    nss_validation: false,
    qemu_validated: true,
    esxi_validation: 'not-tested',
    ssh_default: 'disabled',
    validation: { qemu, esxi: 'not-tested' },
    version,
    tag,
    published_at: publishedAt,
    release_url: `https://github.com/tifycloud/NexaWrt/releases/tag/${tag}`,
    browser_build_workflow_url: 'https://github.com/tifycloud/NexaWrt/actions/workflows/vm-release.yml',
    docs_url: 'https://github.com/tifycloud/NexaWrt/blob/main/docs/VM-X86_64.md',
    assets,
  };
}

const release = makeRelease('official', 'v1.2.3-rc.4', '2026-07-17T12:34:56Z');
assert.equal(validRelease(release, 'official', device), true);
assert.equal(validReleaseGroup({ latest: release, history: [release] }, 'official', device), true);
const vmRelease = makeVmRelease('v0.1.0-rc.3', '2026-07-18T02:00:00Z');
assert.equal(validVmRelease(vmRelease), true);
assert.equal(validVmRelease(vmRelease, 3), true);
assert.equal(validVmReleaseGroup({ latest: vmRelease, history: [vmRelease] }, 3), true);
const vmV1 = makeVmReleaseV4('v0.1.0-rc.3', '2026-07-18T02:00:00Z', 1);
const vmV2 = makeVmReleaseV4('v0.2.0-rc.1', '2026-07-18T03:00:00Z', 2);
assert.equal(validVmRelease(vmV1, 4), true);
assert.equal(validVmRelease(vmV2, 4), true);
assert.equal(validVmReleaseGroup({ latest: vmV2, history: [vmV2, vmV1] }, 4), true);
const vmStable = clone(vmV2);
vmStable.version = 'v0.2.0';
vmStable.tag = 'vm-x86_64-v0.2.0';
vmStable.published_at = '2026-07-18T04:00:00Z';
vmStable.release_url = 'https://github.com/tifycloud/NexaWrt/releases/tag/vm-x86_64-v0.2.0';
vmStable.esxi_validation = 'validated';
vmStable.validation.esxi = 'validated';
for (const asset of Object.values(vmStable.assets)) {
  asset.url = asset.url.replace('/vm-x86_64-v0.2.0-rc.1/', '/vm-x86_64-v0.2.0/');
}
assert.equal(validVmRelease(vmStable, 4), true);
assert.equal(compareVersions(vmStable.version, vmV2.version), 1);
assert.equal(validVmReleaseGroup({ latest: vmStable, history: [vmStable, vmV2, vmV1] }, 4), true);
const invalidStable = clone(vmStable);
invalidStable.assets.raw_bios.name = invalidStable.assets.raw_bios.name.replace('-rc.1', '');
assert.equal(validVmRelease(invalidStable, 4), false);
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
  (value) => { value.artifact_class = 'VM_DISTRIBUTION_IMAGE'; },
  (value) => { value.release_contract = 'vm-x86_64/v1'; },
  (value) => { value.esxi_validation = 'validated'; },
  (value) => { value.validation.qemu.iso_efi = 'boot-pass'; },
  (value) => { value.assets.vmdk_efi.sha256 = '0'.repeat(63); },
  (value) => { value.assets.iso_bios.url = 'https://attacker.invalid/image.iso'; },
  (value) => { delete value.assets.provenance_vmdk_bios; },
]) {
  const invalid = clone(vmV2);
  mutate(invalid);
  assert.equal(validVmRelease(invalid, 4), false);
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
  schema_version: 4,
  repository: 'tifycloud/NexaWrt',
  generated_at: '2026-07-18T02:01:00Z',
  devices: { 'xiaomi-ax9000': clone(device) },
  flavors: {
    official: { latest: official, history: [official] },
    nss: { latest: nss, history: [nss] },
  },
  virtual_images: { x86_64: { latest: vmV2, history: [vmV2, vmV1] } },
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


const componentCatalog = JSON.parse(fs.readFileSync(path.join(root, 'components/catalog.json'), 'utf8'));
componentCatalog.catalog_version = '2026.07.21.1';

function packageRecord(id, packageName, overrides = {}) {
  return {
    id,
    package: packageName,
    version: '1.0.0-r1',
    description: 'Official package fixture',
    feed: 'luci',
    source: 'official',
    installed_size: 4096,
    category: 'network',
    arch: 'x86_64',
    risk: 'standard',
    selectable: true,
    blocked_reason: '',
    ...overrides,
  };
}

function makePackageShard(target, flavor, packages) {
  return {
    schema_version: 2,
    catalog_version: componentCatalog.catalog_version,
    target,
    flavor,
    packages,
  };
}

async function digestText(value) {
  const digest = await webcrypto.subtle.digest('SHA-256', new TextEncoder().encode(value));
  return Buffer.from(digest).toString('hex');
}

const KIDDIN9_CATALOG_SHA256_FIXTURE = '4b14b36b0c9839f81bb6a56ffc1ac94384603c7a9c93e7f63ac48ffc4c699292';

function shardSources(feeds) {
  return feeds.map((feed) => feed === 'kiddin9' ? {
    feed,
    url: 'https://dl.openwrt.ai/releases/25.12/packages/aarch64_cortex-a53/kiddin9/Packages.gz',
    sha256: 'ce97a429f7fcd414a22b3ad701118d5299319a84add12c26d401216184c8bd04',
    metadata_format: 'opkg-packages-gzip',
    metadata_signed: false,
    candidate_repository: 'https://github.com/kiddin9/op-packages.git',
    candidate_commit: '9f2092b4f204fc9948226d9a3f5166b69976af48',
    catalog_sha256: KIDDIN9_CATALOG_SHA256_FIXTURE,
  } : {
    feed,
    url: feed === 'base'
      ? 'https://downloads.openwrt.org/releases/25.12.5/targets/x86/64/packages/packages.adb'
      : `https://downloads.openwrt.org/releases/25.12.5/packages/x86_64/${feed}/packages.adb`,
    sha256: 'a'.repeat(64),
  });
}

async function makePackageCatalogFixtures() {
  const x86Packages = [
    packageRecord('pkg-firewall-plus', 'luci-app-firewall-plus', {
      description: 'filter-probe <img src=x onerror=alert(1)>',
      installed_size: 1536,
    }),
    packageRecord('pkg-storage-extra', 'block-mount-extra', {
      description: 'filter-probe storage helper',
      feed: 'packages',
      installed_size: 2 * 1024 * 1024,
      category: 'storage',
      risk: 'advanced',
    }),
    packageRecord('pkg-system-core', 'kernel-system-core', {
      description: 'filter-probe protected system package',
      feed: 'base',
      installed_size: 8192,
      category: 'system',
      risk: 'system',
      selectable: false,
      blocked_reason: '由基础镜像固定 / Pinned by base image',
    }),
  ];
  for (let index = 0; index < 147; index += 1) {
    const serial = String(index).padStart(3, '0');
    x86Packages.push(packageRecord(`pkg-demo-${serial}`, `luci-app-demo-${serial}`, {
      description: index === 1 ? '' : `demo-search package ${serial}`,
      feed: index % 2 ? 'packages' : 'luci',
      category: index % 3 ? 'services' : 'network',
      risk: index % 5 ? 'standard' : 'advanced',
      installed_size: 1024 + index,
    }));
  }
  const realAxShard = JSON.parse(
    fs.readFileSync(path.join(root, 'components/packages/xiaomi_ax9000-official.json'), 'utf8')
  );
  const communityPackages = realAxShard.packages
    .filter((record) => record.source === 'kiddin9')
    .map((record) => clone(record));
  assert.equal(communityPackages.length, 969);
  assert.equal(communityPackages.some((record) => record.package === 'luci-app-openclash'), true);
  const axOfficialPackages = [
    packageRecord('pkg-ax-mesh', 'mesh11sd', { description: 'AX official mesh', feed: 'packages', arch: 'aarch64_cortex-a53' }),
    // Preserve the reviewed projection order from the generated shard.
    ...communityPackages,
  ];
  const shards = [
    makePackageShard('x86_64', 'official', x86Packages),
    makePackageShard('xiaomi_ax9000', 'official', axOfficialPackages),
    makePackageShard('xiaomi_ax9000', 'nss', [
      packageRecord('pkg-ax-nss-monitor', 'luci-app-nss-monitor', { description: 'AX NSS monitor', arch: 'noarch' }),
    ]),
  ];
  const paths = [
    'packages/x86_64-official.json',
    'packages/xiaomi_ax9000-official.json',
    'packages/xiaomi_ax9000-nss.json',
  ];
  const rawByPath = new Map();
  const descriptors = [];
  for (let index = 0; index < shards.length; index += 1) {
    const shard = shards[index];
    const raw = JSON.stringify(shard);
    rawByPath.set(`components/${paths[index]}`, raw);
    const feeds = [...new Set(shard.packages.map((record) => record.feed))].sort();
    descriptors.push({
      target: shard.target,
      flavor: shard.flavor,
      path: paths[index],
      sha256: await digestText(raw),
      package_count: shard.packages.length,
      selectable_count: shard.packages.filter((record) => record.selectable).length,
      sources: shardSources(feeds),
    });
  }

  const purposes = {};
  const qualityCounts = { exact: 0, family: 0, category: 0 };
  for (const shard of shards) {
    for (const record of shard.packages) {
      const key = `${record.source}/${record.package}`;
      if (Object.hasOwn(purposes, key)) continue;
      let purpose = `用于管理或扩展 ${record.package} 相关功能。`;
      let quality = 'category';
      if (key === 'official/luci-app-firewall-plus') {
        purpose = '防火墙网页管理、访问控制和规则配置。';
        quality = 'exact';
      } else if (key === 'official/block-mount-extra') {
        purpose = '提供存储挂载相关软件包家族功能。';
        quality = 'family';
      } else if (key === 'official/luci-app-demo-042') {
        purpose = '中文搜索测试：演示网页组件与服务管理。';
        quality = 'exact';
      } else if (key === 'kiddin9/luci-app-openclash') {
        purpose = '代理管理、策略分流与订阅配置。';
        quality = 'exact';
      }
      purposes[key] = { purpose, quality };
      qualityCounts[quality] += 1;
    }
  }
  const purposeCatalog = {
    schema_version: 1,
    catalog_version: componentCatalog.catalog_version,
    package_count: Object.keys(purposes).length,
    quality_counts: qualityCounts,
    purposes,
  };
  const purposePath = 'components/package-purpose-zh.json';
  const purposeRaw = JSON.stringify(purposeCatalog);
  rawByPath.set(purposePath, purposeRaw);

  return {
    root: {
      schema_version: 3,
      catalog_version: componentCatalog.catalog_version,
      openwrt_version: '25.12.5',
      purpose_catalog: {
        locale: 'zh-CN',
        path: purposePath,
        sha256: await digestText(purposeRaw),
        package_count: purposeCatalog.package_count,
      },
      shards: descriptors,
    },
    shards,
    purposeCatalog,
    purposePath,
    rawByPath,
  };
}

async function loadCatalogWith(responseFactory, cryptoImpl = webcrypto) {
  context.fetch = responseFactory;
  context.crypto = cryptoImpl;
  try {
    await loadComponentCatalog();
  } finally {
    context.crypto = webcrypto;
  }
}

function fixtureFetch(fixtures, calls, rawOverride = new Map()) {
  return async (url, options) => {
    calls.push(url);
    assert.equal(options.cache, 'no-store');
    assert.equal(options.credentials, 'same-origin');
    if (url === 'components/catalog.json') return { ok: true, json: async () => clone(componentCatalog) };
    if (url === 'components/package-catalog.json') return { ok: true, json: async () => clone(fixtures.root) };
    if (fixtures.rawByPath.has(url)) {
      return { ok: true, text: async () => rawOverride.has(url) ? rawOverride.get(url) : fixtures.rawByPath.get(url) };
    }
    throw new Error(`unexpected fetch: ${url}`);
  };
}

function flattenChildren(element) {
  const output = [];
  for (const child of element.children) output.push(child, ...flattenChildren(child));
  return output;
}

function flattenedText(selector) {
  return flattenChildren(document.querySelector(selector)).map((item) => item.textContent).join(' ');
}

function packageOptions() {
  return flattenChildren(document.querySelector('#component-list'))
    .filter((item) => item.className.split(' ').includes('package-option'));
}

function backendResolution(target, flavor, requestedIds) {
  const args = [path.join(root, 'scripts/resolve-components.py'), '--target', target, '--flavor', flavor];
  for (const id of requestedIds) args.push('--component', id);
  return JSON.parse(execFileSync('python3', args, { cwd: root, encoding: 'utf8' }));
}

async function assertFrontendBackendHashContract(target, flavor, requestedIds, packageRecords) {
  setCurrentPackageRecords(packageRecords);
  const frontend = resolveComponentSelection(componentCatalog, target, requestedIds);
  assert.equal(frontend.ok, true, frontend.error);
  const backend = backendResolution(target, flavor, requestedIds);
  assert.deepEqual([...frontend.requested_components], backend.requested_components);
  assert.deepEqual([...frontend.default_components], backend.default_components);
  assert.deepEqual([...frontend.resolved_components], backend.resolved_components);
  assert.deepEqual([...frontend.packages], backend.packages);
  const frontendHash = await sha256Hex(canonicalJson(componentHashPayload(componentCatalog, target, flavor, frontend)));
  assert.equal(frontendHash, backend.request_hash, `${target}/${flavor}: ${requestedIds.join(',') || '<defaults>'}`);
}

(async () => {
  const packageFixtures = await makePackageCatalogFixtures();
  assert.equal(validateComponentCatalog(componentCatalog), true);
  assert.equal(validatePackageCatalogRoot(packageFixtures.root, componentCatalog), true);
  assert.equal(
    validatePackagePurposeCatalog(packageFixtures.purposeCatalog, componentCatalog, packageFixtures.root.purpose_catalog),
    true
  );
  const purposeTextBoundary = clone(packageFixtures.purposeCatalog);
  purposeTextBoundary.purposes['official/luci-app-firewall-plus'].purpose = '中'.repeat(359);
  assert.equal(validatePackagePurposeCatalog(purposeTextBoundary, componentCatalog, packageFixtures.root.purpose_catalog), true);
  purposeTextBoundary.purposes['official/luci-app-firewall-plus'].purpose = '中'.repeat(360);
  assert.equal(validatePackagePurposeCatalog(purposeTextBoundary, componentCatalog, packageFixtures.root.purpose_catalog), true);
  purposeTextBoundary.purposes['official/luci-app-firewall-plus'].purpose = '中'.repeat(361);
  assert.equal(validatePackagePurposeCatalog(purposeTextBoundary, componentCatalog, packageFixtures.root.purpose_catalog), false);
  purposeTextBoundary.purposes['official/luci-app-firewall-plus'].purpose = '兼容汉字：豈';
  assert.equal(validatePackagePurposeCatalog(purposeTextBoundary, componentCatalog, packageFixtures.root.purpose_catalog), true);
  purposeTextBoundary.purposes['official/luci-app-firewall-plus'].purpose = '包含双向控制符：‮';
  assert.equal(validatePackagePurposeCatalog(purposeTextBoundary, componentCatalog, packageFixtures.root.purpose_catalog), false);
  purposeTextBoundary.purposes['official/luci-app-firewall-plus'].purpose = '   ';
  assert.equal(validatePackagePurposeCatalog(purposeTextBoundary, componentCatalog, packageFixtures.root.purpose_catalog), false);
  assert.equal(validatePackageCatalogShard(packageFixtures.shards[0], packageFixtures.root.shards[0], componentCatalog), true);
  assert.equal(validatePackageCatalogShard(packageFixtures.shards[1], packageFixtures.root.shards[1], componentCatalog), true);
  assert.equal(await validCommunityCandidateProjection(packageFixtures.shards[1], packageFixtures.root.shards[1]), true);
  const invalidRoot = clone(packageFixtures.root);
  invalidRoot.extra = true;
  assert.equal(validatePackageCatalogRoot(invalidRoot, componentCatalog), false);
  const invalidShard = clone(packageFixtures.shards[0]);
  invalidShard.packages[0].unexpected = 'field';
  assert.equal(validatePackageCatalogShard(invalidShard, packageFixtures.root.shards[0], componentCatalog), false);

  const realPackageShards = {
    'x86_64/official': JSON.parse(fs.readFileSync(path.join(root, 'components/packages/x86_64-official.json'), 'utf8')).packages,
    'xiaomi_ax9000/official': JSON.parse(fs.readFileSync(path.join(root, 'components/packages/xiaomi_ax9000-official.json'), 'utf8')).packages,
    'xiaomi_ax9000/nss': JSON.parse(fs.readFileSync(path.join(root, 'components/packages/xiaomi_ax9000-nss.json'), 'utf8')).packages,
  };
  const sqmPackageId = realPackageShards['x86_64/official'].find((record) => record.package === 'luci-app-sqm').id;
  await assertFrontendBackendHashContract('x86_64', 'official', [], realPackageShards['x86_64/official']);
  await assertFrontendBackendHashContract('x86_64', 'official', ['wireguard'], realPackageShards['x86_64/official']);
  await assertFrontendBackendHashContract('x86_64', 'official', [sqmPackageId], realPackageShards['x86_64/official']);
  await assertFrontendBackendHashContract('x86_64', 'official', ['wireguard', sqmPackageId], realPackageShards['x86_64/official']);
  await assertFrontendBackendHashContract('xiaomi_ax9000', 'official', [sqmPackageId], realPackageShards['xiaomi_ax9000/official']);
  await assertFrontendBackendHashContract('xiaomi_ax9000', 'nss', [sqmPackageId], realPackageShards['xiaomi_ax9000/nss']);

  const invalidCatalog = clone(componentCatalog);
  invalidCatalog.components.find((item) => item.id === 'wireguard').depends = ['missing-component'];
  assert.equal(validateComponentCatalog(invalidCatalog), false);
  const cyclicCatalog = clone(componentCatalog);
  cyclicCatalog.components.find((item) => item.id === 'web-ui').depends = ['wireguard'];
  assert.equal(validateComponentCatalog(cyclicCatalog), false);
  const asymmetricCatalog = clone(componentCatalog);
  asymmetricCatalog.components.find((item) => item.id === 'qosify').conflicts = [];
  assert.equal(validateComponentCatalog(asymmetricCatalog), false);

  const dependencySelection = resolveComponentSelection(componentCatalog, 'x86_64', ['wireguard']);
  assert.equal(dependencySelection.ok, true);
  assert.deepEqual([...dependencySelection.requested_components], ['wireguard']);
  assert.deepEqual([...dependencySelection.default_components], ['diagnostic-tools', 'web-ui']);
  assert.deepEqual([...dependencySelection.resolved_components], ['diagnostic-tools', 'web-ui', 'wireguard']);
  assert.equal(dependencySelection.packages.includes('wireguard-tools'), true);
  const conflictingSelection = resolveComponentSelection(componentCatalog, 'x86_64', ['sqm', 'qosify']);
  assert.equal(conflictingSelection.ok, false);
  assert.match(conflictingSelection.error, /组件冲突/);
  assert.equal(resolveComponentSelection(componentCatalog, 'xiaomi_ax9000', ['pppoe-server']).ok, false);

  const hashPayload = componentHashPayload(componentCatalog, 'x86_64', 'official', dependencySelection);
  assert.equal(canonicalJson(hashPayload), '{"catalog_version":"2026.07.21.1","community_packages":[],"default_components":["diagnostic-tools","web-ui"],"flavor":"official","packages":["ca-bundle","curl","ethtool","iperf3","kmod-wireguard","luci-app-firewall","luci-base","luci-proto-wireguard","luci-ssl","tcpdump","wireguard-tools"],"requested_components":["wireguard"],"resolved_components":["diagnostic-tools","web-ui","wireguard"],"schema_version":2,"target":"x86_64"}');
  const normalizedHash = await sha256Hex(canonicalJson(hashPayload));
  assert.equal(normalizedHash, 'cb47ea8fef1232db432d9525712c53f8256a1256a59414e5ea0cab3830b11808');
  const normalized = normalizedBuildRequest(componentCatalog, 'official', dependencySelection, normalizedHash);
  assert.match(actionsInputs(normalized), /^target=x86_64\nflavor=official\ncomponents=wireguard\ncatalog_version=2026\.07\.21\.1\nrequest_hash=cb47ea8fef1232db432d9525712c53f8256a1256a59414e5ea0cab3830b11808$/);

  const delayedCrypto = {
    subtle: {
      async digest(...args) {
        await new Promise((resolve) => setTimeout(resolve, 5));
        return webcrypto.subtle.digest(...args);
      },
    },
  };
  const initialCalls = [];
  await loadCatalogWith(fixtureFetch(packageFixtures, initialCalls), delayedCrypto);
  assert.deepEqual(initialCalls, [
    'components/catalog.json',
    'components/package-catalog.json',
    'components/package-purpose-zh.json',
    'components/packages/x86_64-official.json',
  ]);
  assert.equal(document.querySelector('#component-status').classList.contains('error'), false);
  assert.equal(document.querySelector('#component-package-status').classList.contains('error'), false);
  assert.match(document.querySelector('#component-package-status').textContent, /OpenWrt 25\.12\.5/);
  assert.match(document.querySelector('#component-package-status').textContent, /中文目录完整性已验证/);
  assert.match(
    document.querySelector('#component-package-status').textContent,
    new RegExp(`人工精确 ${packageFixtures.purposeCatalog.quality_counts.exact} / 家族规则 ${packageFixtures.purposeCatalog.quality_counts.family} / 分类概述 ${packageFixtures.purposeCatalog.quality_counts.category}`)
  );
  assert.equal(initialCalls.includes('components/package-purpose-zh.json'), true);
  assert.match(document.querySelector('#component-package-status').textContent, /150 个包，149 个可选择/);
  assert.equal(document.querySelector('#component-target').disabled, false);
  assert.equal(document.querySelector('#component-target').value, 'x86_64');
  assert.equal(document.querySelector('#component-flavor').value, 'official');
  assert.equal(getCurrentPackageRecords().length, 150);
  const selectableOfficialPackages = getCurrentPackageRecords().filter((record) => record.selectable);
  const maximumOfficialPackages = selectableOfficialPackages.slice(0, componentCatalog.max_selected_components).map((record) => record.id);
  assert.equal(resolveComponentSelection(componentCatalog, 'x86_64', maximumOfficialPackages).ok, true);
  const tooManyOfficialPackages = selectableOfficialPackages.slice(0, componentCatalog.max_selected_components + 1).map((record) => record.id);
  assert.equal(resolveComponentSelection(componentCatalog, 'x86_64', tooManyOfficialPackages).ok, false);
  assert.match(resolveComponentSelection(componentCatalog, 'x86_64', tooManyOfficialPackages).error, new RegExp(`最多可显式选择 ${componentCatalog.max_selected_components} 个组件`));
  assert.deepEqual([...getRequestedComponentIds()], []);
  assert.deepEqual([...getResolvedComponentIds()].sort(), ['diagnostic-tools', 'web-ui']);
  assert.match(document.querySelector('#component-request-hash').textContent, /^sha256:[a-f0-9]{64}$/);
  assert.equal(document.querySelector('#custom-build-workflow-link').href, 'https://github.com/tifycloud/NexaWrt/actions/workflows/custom-build.yml');
  assert.equal(document.querySelector('#custom-build-workflow-link').hidden, false);
  assert.match(document.querySelector('#component-actions-inputs').textContent, /components=\n/);
  assert.equal(packageOptions().length, 100);
  assert.match(document.querySelector('#component-result-status').textContent, /无需搜索即可浏览：共 150 个软件包，当前显示第 1–100 个/);
  assert.match(flattenedText('#component-list'), /精选套餐/);
  assert.match(flattenedText('#component-list'), /用途 \/ Purpose：/);
  assert.match(flattenedText('#component-list'), /中文用途（人工精确）：防火墙网页管理、访问控制和规则配置。/);
  assert.match(flattenedText('#component-list'), /上游说明 \/ Upstream：filter-probe/);
  assert.match(flattenedText('#component-list'), /第 1 \/ 2 页/);
  const nextPage = flattenChildren(document.querySelector('#component-list'))
    .find((item) => item.getAttribute('data-package-page-next') === 'true');
  assert.ok(nextPage);
  nextPage.dispatchEvent({ type: 'click' });
  assert.equal(packageOptions().length, 50);
  assert.match(document.querySelector('#component-result-status').textContent, /当前显示第 101–150 个/);
  assert.match(flattenedText('#component-list'), /第 2 \/ 2 页/);
  await changeComponentSelection('pkg-demo-100', true);
  assert.equal(packageOptions().length, 50);
  assert.match(document.querySelector('#component-result-status').textContent, /当前显示第 101–150 个/);
  await changeComponentSelection('pkg-demo-100', false);

  document.querySelector('#component-search').value = 'demo-search';
  renderComponentChoices();
  assert.equal(packageOptions().length, 100);
  assert.match(document.querySelector('#component-result-status').textContent, /共 146 个软件包，当前显示第 1–100 个/);
  assert.match(flattenedText('#component-list'), /第 1 \/ 2 页/);

  document.querySelector('#component-search').value = '中文搜索测试';
  renderComponentChoices();
  assert.equal(packageOptions().length, 1);
  assert.match(flattenedText('#component-list'), /luci-app-demo-042/);
  assert.match(flattenedText('#component-list'), /中文用途（人工精确）：中文搜索测试：演示网页组件与服务管理。/);

  document.querySelector('#component-search').value = 'block-mount-extra';
  renderComponentChoices();
  assert.equal(packageOptions().length, 1);
  assert.match(flattenedText('#component-list'), /中文用途（家族规则生成）：提供存储挂载相关软件包家族功能。/);

  document.querySelector('#component-search').value = 'luci-app-demo-001';
  renderComponentChoices();
  assert.equal(packageOptions().length, 1);
  assert.match(flattenedText('#component-list'), /中文用途（分类概述，具体用途请核对上游）：用于管理或扩展 luci-app-demo-001 相关功能。/);
  assert.match(flattenedText('#component-list'), /上游说明 \/ Upstream：上游未提供说明 \/ No upstream description/);

  document.querySelector('#component-source').value = 'official';
  document.querySelector('#component-search').value = 'filter-probe';
  document.querySelector('#component-category').value = 'network';
  document.querySelector('#component-risk').value = 'standard';
  document.querySelector('#component-feed').value = 'luci';
  renderComponentChoices();
  const filteredText = flattenedText('#component-list');
  assert.match(filteredText, /luci-app-firewall-plus/);
  assert.doesNotMatch(filteredText, /block-mount-extra/);
  assert.doesNotMatch(filteredText, /kernel-system-core/);
  assert.match(filteredText, /1\.5 KiB/);
  assert.match(filteredText, /standard/);
  assert.match(filteredText, /<img src=x onerror=alert\(1\)>/);
  assert.equal(flattenChildren(document.querySelector('#component-list')).some((item) => item.tagName === 'img'), false);

  document.querySelector('#component-category').value = '';
  document.querySelector('#component-risk').value = 'system';
  document.querySelector('#component-feed').value = 'base';
  renderComponentChoices();
  const blockedOption = packageOptions()[0];
  assert.equal(blockedOption.children[0].disabled, true);
  assert.match(flattenedText('#component-list'), /由基础镜像固定/);

  document.querySelector('#component-risk').value = 'standard';
  document.querySelector('#component-feed').value = 'luci';
  await changeComponentSelection('pkg-firewall-plus', true);
  assert.equal(getRequestedComponentIds().includes('pkg-firewall-plus'), true);
  assert.match(document.querySelector('#component-packages').textContent, /luci-app-firewall-plus/);
  assert.match(document.querySelector('#component-normalized').textContent, /"pkg-firewall-plus"/);
  assert.match(document.querySelector('#component-actions-inputs').textContent, /components=pkg-firewall-plus/);
  assert.match(flattenedText('#component-selected-official'), /luci-app-firewall-plus/);

  const conflictPrevious = [...getRequestedComponentIds()];
  await changeComponentSelection('sqm', true);
  await changeComponentSelection('qosify', true);
  assert.deepEqual([...getRequestedComponentIds()].sort(), [...conflictPrevious, 'sqm'].sort());
  assert.equal(document.querySelector('#component-error').classList.contains('error'), true);
  assert.match(document.querySelector('#component-error').textContent, /组件冲突/);

  document.querySelector('#component-target').value = 'xiaomi_ax9000';
  document.querySelector('#component-target').dispatchEvent({ type: 'change' });
  assert.equal(getCurrentPackageRecords().length, 0);
  assert.equal(packageOptions().length, 0);
  await new Promise((resolve) => setTimeout(resolve, 30));
  assert.equal(getRequestedComponentIds().includes('pkg-firewall-plus'), false);
  assert.equal(
    getCurrentPackageRecords().length,
    970,
    `${document.querySelector('#component-package-status').textContent} ${JSON.stringify(loggedErrors.slice(-3))}`
  );
  const openClashCandidate = getCurrentPackageRecords().find(
    (record) => record.source === 'kiddin9' && record.package === 'luci-app-openclash'
  );
  assert.ok(openClashCandidate);
  assert.equal(openClashCandidate.selectable, false);
  assert.equal(initialCalls.includes('components/packages/xiaomi_ax9000-official.json'), true);

  document.querySelector('#component-search').value = 'openclash';
  document.querySelector('#component-source').value = 'kiddin9';
  document.querySelector('#component-category').value = '';
  document.querySelector('#component-risk').value = '';
  document.querySelector('#component-feed').value = 'kiddin9';
  renderComponentChoices();
  const openClashOptions = packageOptions();
  assert.equal(openClashOptions.length, 1);
  assert.match(flattenedText('#component-list'), /luci-app-openclash/);
  assert.match(flattenedText('#component-list'), /kiddin9/);
  assert.equal(openClashOptions[0].children[0].disabled, true);
  await changeComponentSelection(openClashCandidate.id, true);
  assert.equal(getRequestedComponentIds().includes(openClashCandidate.id), false);

  document.querySelector('#component-search').value = '';
  document.querySelector('#component-source').value = '';
  document.querySelector('#component-category').value = '';
  document.querySelector('#component-risk').value = '';
  document.querySelector('#component-feed').value = '';
  document.querySelector('#component-flavor').value = 'nss';
  document.querySelector('#component-flavor').dispatchEvent({ type: 'change' });
  await new Promise((resolve) => setTimeout(resolve, 30));
  assert.deepEqual([...getCurrentPackageRecords()].map((record) => record.id), ['pkg-ax-nss-monitor']);
  assert.equal(initialCalls.includes('components/packages/xiaomi_ax9000-nss.json'), true);
  document.querySelector('#component-target').value = 'x86_64';
  document.querySelector('#component-target').dispatchEvent({ type: 'change' });
  await new Promise((resolve) => setTimeout(resolve, 30));
  assert.equal(getCurrentPackageRecords().length, 150);
  assert.equal(initialCalls.filter((url) => url === 'components/packages/x86_64-official.json').length, 1);

  clearVerifiedPackageShardCache();
  context.crypto = delayedCrypto;
  document.querySelector('#component-target').value = 'xiaomi_ax9000';
  document.querySelector('#component-target').dispatchEvent({ type: 'change' });
  document.querySelector('#component-target').value = 'x86_64';
  document.querySelector('#component-target').dispatchEvent({ type: 'change' });
  await new Promise((resolve) => setTimeout(resolve, 80));
  context.crypto = webcrypto;
  assert.equal(document.querySelector('#component-target').value, 'x86_64');
  assert.equal(getCurrentPackageRecords().length, 150);
  assert.match(document.querySelector('#component-package-status').textContent, /10947|150/);

  clearVerifiedPackageShardCache();
  const purposeShaCalls = [];
  const tamperedPurpose = new Map([[
    packageFixtures.purposePath,
    `${packageFixtures.rawByPath.get(packageFixtures.purposePath)} `,
  ]]);
  await loadCatalogWith(fixtureFetch(packageFixtures, purposeShaCalls, tamperedPurpose));
  assert.equal(document.querySelector('#component-package-status').classList.contains('error'), true);
  assert.match(document.querySelector('#component-package-status').textContent, /中文用途目录不可用/);
  assert.equal(getCurrentPackageRecords().length, 0);
  assert.equal(purposeShaCalls.includes('components/packages/x86_64-official.json'), false);
  assert.match(loggedErrors.at(-1)[1].message, /purpose catalog sha256 mismatch/);

  clearVerifiedPackageShardCache();
  const missingPurposeFixtures = {
    root: clone(packageFixtures.root),
    shards: clone(packageFixtures.shards),
    purposeCatalog: clone(packageFixtures.purposeCatalog),
    purposePath: packageFixtures.purposePath,
    rawByPath: new Map(packageFixtures.rawByPath),
  };
  const missingPurposeKey = 'official/luci-app-firewall-plus';
  const missingPurposeQuality = missingPurposeFixtures.purposeCatalog.purposes[missingPurposeKey].quality;
  delete missingPurposeFixtures.purposeCatalog.purposes[missingPurposeKey];
  missingPurposeFixtures.purposeCatalog.package_count -= 1;
  missingPurposeFixtures.purposeCatalog.quality_counts[missingPurposeQuality] -= 1;
  const missingPurposeRaw = JSON.stringify(missingPurposeFixtures.purposeCatalog);
  missingPurposeFixtures.rawByPath.set(missingPurposeFixtures.purposePath, missingPurposeRaw);
  missingPurposeFixtures.root.purpose_catalog.package_count = missingPurposeFixtures.purposeCatalog.package_count;
  missingPurposeFixtures.root.purpose_catalog.sha256 = await digestText(missingPurposeRaw);
  await loadCatalogWith(fixtureFetch(missingPurposeFixtures, []));
  assert.equal(document.querySelector('#component-package-status').classList.contains('error'), true);
  assert.match(document.querySelector('#component-package-status').textContent, /官方包校验失败/);
  assert.equal(getCurrentPackageRecords().length, 0);
  assert.match(loggedErrors.at(-1)[1].message, /does not cover this shard/);

  clearVerifiedPackageShardCache();
  const mismatchCalls = [];
  const tampered = new Map([[
    'components/packages/x86_64-official.json',
    `${packageFixtures.rawByPath.get('components/packages/x86_64-official.json')} `,
  ]]);
  await loadCatalogWith(fixtureFetch(packageFixtures, mismatchCalls, tampered));
  assert.equal(document.querySelector('#component-package-status').classList.contains('error'), true);
  assert.match(document.querySelector('#component-package-status').textContent, /官方包校验失败/);
  assert.equal(getCurrentPackageRecords().length, 0);
  assert.equal(document.querySelector('#custom-build-workflow-link').hidden, false);
  assert.deepEqual([...getResolvedComponentIds()].sort(), ['diagnostic-tools', 'web-ui']);

  for (const field of ['sha256', 'catalog_sha256']) {
    clearVerifiedPackageShardCache();
    const forgedFixtures = {
      ...packageFixtures,
      root: clone(packageFixtures.root),
    };
    const communityDescriptor = forgedFixtures.root.shards.find(
      (item) => item.target === 'xiaomi_ax9000' && item.flavor === 'official'
    );
    communityDescriptor.sources.find((source) => source.feed === 'kiddin9')[field] = '0'.repeat(64);
    await loadCatalogWith(fixtureFetch(forgedFixtures, []));
    assert.equal(document.querySelector('#component-package-status').classList.contains('error'), true);
    assert.equal(getCurrentPackageRecords().length, 0);
  }

  clearVerifiedPackageShardCache();
  const projectionFixtures = {
    root: clone(packageFixtures.root),
    shards: clone(packageFixtures.shards),
    rawByPath: new Map(packageFixtures.rawByPath),
  };
  const axProjectionShard = projectionFixtures.shards.find(
    (item) => item.target === 'xiaomi_ax9000' && item.flavor === 'official'
  );
  axProjectionShard.packages.find(
    (record) => record.source === 'kiddin9' && record.package === 'luci-app-openclash'
  ).description += ' tampered';
  const axProjectionPath = 'components/packages/xiaomi_ax9000-official.json';
  const axProjectionRaw = JSON.stringify(axProjectionShard);
  projectionFixtures.rawByPath.set(axProjectionPath, axProjectionRaw);
  projectionFixtures.root.shards.find(
    (item) => item.target === 'xiaomi_ax9000' && item.flavor === 'official'
  ).sha256 = await digestText(axProjectionRaw);
  await loadCatalogWith(fixtureFetch(projectionFixtures, []));
  document.querySelector('#component-target').value = 'xiaomi_ax9000';
  await loadPackageShardForSelection();
  assert.equal(document.querySelector('#component-package-status').classList.contains('error'), true);
  assert.match(document.querySelector('#component-package-status').textContent, /官方包校验失败/);
  assert.equal(getCurrentPackageRecords().length, 0);

  await loadCatalogWith(async (url, options) => {
    assert.equal(options.cache, 'no-store');
    assert.equal(options.credentials, 'same-origin');
    if (url === 'components/catalog.json') return { ok: true, json: async () => clone(componentCatalog) };
    if (url === 'components/package-catalog.json') return { ok: false, status: 503, json: async () => ({}) };
    throw new Error(`unexpected fetch: ${url}`);
  });
  assert.equal(document.querySelector('#component-package-status').classList.contains('error'), true);
  assert.equal(document.querySelector('#custom-build-workflow-link').hidden, false);
  assert.match(flattenedText('#component-list'), /精选套餐/);

  await loadCatalogWith(async () => ({ ok: true, json: async () => ({ schema_version: 999 }) }));
  assert.equal(document.querySelector('#component-status').classList.contains('error'), true);
  assert.equal(document.querySelector('#custom-build-workflow-link').hidden, true);
  assert.equal(document.querySelector('#custom-build-workflow-link').href, undefined);
  assert.equal(document.querySelector('#copy-actions-inputs').disabled, true);


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
  assert.equal(vmCard.querySelector('[data-vm-field="downloads"]').children[0].href, vmV2.assets.raw_bios.url);
  assert.equal(vmCard.querySelector('[data-vm-field="downloads"]').children.length, 7);
  assert.equal(vmCard.querySelector('[data-vm-field="provenance"]').children.length, 6);
  assert.equal(vmCard.querySelector('[data-vm-field="release-url"]').href, vmV2.release_url);
  assert.equal(vmCard.querySelector('[data-vm-field="support-links"]').children[0].href, vmV2.browser_build_workflow_url);
  assert.equal(vmCard.querySelector('[data-vm-field="support-links"]').children.length, 2);
  assert.equal(vmCard.querySelector('details').hidden, false);
  const vmHistoryActions = document.querySelector('#vm-history-actions');
  assert.equal(vmHistoryActions.hidden, false);
  assert.equal(vmHistoryActions.children.length, 1);
  assert.equal(vmHistoryActions.children[0].href, vmV2.browser_build_workflow_url);

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
  assert.equal(validVmCardWithInvalidAx.querySelector('[data-vm-field="downloads"]').children[0].href, vmV2.assets.raw_bios.url);
  assert.equal(validVmCardWithInvalidAx.querySelector('[data-vm-field="support-links"]').children[0].href, vmV2.browser_build_workflow_url);
  assert.equal(validVmCardWithInvalidAx.querySelector('[data-vm-field="release-url"]').hidden, false);
  assert.equal(document.querySelector('#vm-history-actions').hidden, false);
  assert.equal(document.querySelector('#vm-history-actions').children[0].href, vmV2.browser_build_workflow_url);
  assert.equal(document.querySelector('#data-status').classList.contains('error'), false);

  const invalidAxDeviceOnly = clone(validIndex);
  invalidAxDeviceOnly.devices['xiaomi-ax9000'].production_ready = true;
  await loadWith(async () => ({ ok: true, json: async () => invalidAxDeviceOnly }));
  assert.equal(document.querySelector('#browser-build-link').hidden, true);
  assert.equal(document.querySelector('[data-vm-platform="x86_64"]').querySelector('[data-vm-field="release-url"]').href, vmV2.release_url);
  assert.equal(document.querySelector('[data-vm-platform="x86_64"]').querySelector('[data-vm-field="support-links"]').children[0].href, vmV2.browser_build_workflow_url);
  assert.equal(document.querySelector('#vm-history-actions').children[0].href, vmV2.browser_build_workflow_url);

  await loadWith(async () => ({ ok: true, json: async () => ({ schema_version: 999 }) }));
  assertSafeEmptyState();

  await loadWith(async () => ({ ok: true, json: async () => { throw new SyntaxError('bad json'); } }));
  assertSafeEmptyState();

  await loadWith(async () => ({ ok: false, status: 503, json: async () => ({}) }));
  assertSafeEmptyState();

  await loadWith(async () => { throw new Error('network down'); });
  assertSafeEmptyState();
  assert.equal(loggedErrors.length >= 5, true);

  console.log('Pages UI policy: release rendering plus fail-closed package and Chinese-purpose catalogs, Chinese search, normalized request hashing, and authenticated Actions handoff');
})().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
