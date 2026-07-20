'use strict';

const REPOSITORY = 'tifycloud/NexaWrt';
const DEVICE_ID = 'xiaomi-ax9000';
const FLAVORS = ['official', 'nss'];
const VM_PLATFORM = 'x86_64';
const BUILD_WORKFLOW_URL = `https://github.com/${REPOSITORY}/actions/workflows/build.yml`;
const RECOVERY_URL = `https://github.com/${REPOSITORY}/blob/main/docs/RECOVERY.md`;
const TESTING_URL = `https://github.com/${REPOSITORY}/blob/main/docs/TESTING.md`;
const VM_RELEASE_WORKFLOW_URL = `https://github.com/${REPOSITORY}/actions/workflows/vm-release.yml`;
const VM_DOCS_URL = `https://github.com/${REPOSITORY}/blob/main/docs/VM-X86_64.md`;
const PROVENANCE_LABELS = {
  provenance_archive: 'Archive bundle',
  provenance_checksums: 'Checksums bundle',
  provenance_firmware: 'Firmware bundle',
  provenance_sbom: 'SBOM bundle'
};
const VM_VARIANTS = ['raw_bios', 'iso_bios', 'iso_efi', 'vmdk_bios', 'vmdk_efi'];
const VM_DOWNLOAD_LABELS = {
  raw_bios: 'RAW BIOS (.img.gz) ↓',
  iso_bios: 'BIOS Live ISO ↓',
  iso_efi: 'EFI Live ISO ↓',
  vmdk_bios: 'BIOS VMDK ↓',
  vmdk_efi: 'EFI VMDK ↓'
};
const VM_V1_PROVENANCE_LABELS = {
  provenance_image: 'RAW image bundle',
  provenance_checksums: 'Checksums bundle'
};
const VM_V2_PROVENANCE_LABELS = {
  provenance_raw_bios: 'RAW BIOS bundle',
  provenance_iso_bios: 'BIOS ISO bundle',
  provenance_iso_efi: 'EFI ISO bundle',
  provenance_vmdk_bios: 'BIOS VMDK bundle',
  provenance_vmdk_efi: 'EFI VMDK bundle',
  provenance_checksums: 'Checksums bundle'
};

function exactKeys(value, expected) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return false;
  const actual = Object.keys(value).sort();
  const required = [...expected].sort();
  return actual.length === required.length && actual.every((key, index) => key === required[index]);
}

function validUtcTimestamp(value) {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(value)) return false;
  const parsed = new Date(value);
  return !Number.isNaN(parsed.getTime()) && parsed.toISOString().replace('.000Z', 'Z') === value;
}

function makeLink(label, url, className = '') {
  const link = document.createElement('a');
  link.textContent = label;
  link.href = url;
  link.target = '_blank';
  link.rel = 'noopener noreferrer';
  if (className) link.className = className;
  return link;
}

function validHttpsGitHubUrl(value, expectedPath) {
  try {
    const url = new URL(value);
    return url.protocol === 'https:' && url.hostname === 'github.com' &&
      url.username === '' && url['password'] === '' && url.port === '' &&
      url.search === '' && url.hash === '' && url.pathname === expectedPath;
  } catch {
    return false;
  }
}

function validDevice(device) {
  const keys = [
    'schema', 'id', 'display_name', 'vendor', 'model', 'target', 'subtarget', 'profile',
    'hardware_status', 'production_ready', 'website_visible', 'image_capabilities',
    'flavors', 'channels', 'browser_build_workflow_url', 'recovery_url', 'testing_url'
  ];
  if (!exactKeys(device, keys) || device.schema !== 1 || device.id !== DEVICE_ID ||
      device.display_name !== 'Xiaomi AX9000' || device.vendor !== 'Xiaomi' || device.model !== 'AX9000' ||
      device.target !== 'qualcommax' || device.subtarget !== 'ipq807x' || device.profile !== 'xiaomi_ax9000' ||
      device.hardware_status !== 'unverified' || device.production_ready !== false ||
      device.website_visible !== true) return false;
  if (!exactKeys(device.image_capabilities, ['ram_boot', 'factory', 'sysupgrade']) ||
      device.image_capabilities.ram_boot !== true || device.image_capabilities.factory !== false ||
      device.image_capabilities.sysupgrade !== false) return false;
  if (!exactKeys(device.flavors, FLAVORS) ||
      !exactKeys(device.flavors.official, ['experimental']) || device.flavors.official.experimental !== false ||
      !exactKeys(device.flavors.nss, ['experimental']) || device.flavors.nss.experimental !== true) return false;
  if (!Array.isArray(device.channels) || device.channels.length !== 1 || device.channels[0] !== 'ram-test') return false;
  return device.browser_build_workflow_url === BUILD_WORKFLOW_URL &&
    device.recovery_url === RECOVERY_URL && device.testing_url === TESTING_URL;
}

function validRelease(release, flavor, device) {
  const keys = [
    'device_id', 'device_name', 'flavor', 'flavor_experimental', 'channel', 'hardware_status',
    'production_ready', 'ram_only', 'version', 'tag', 'published_at', 'release_url',
    'browser_build_workflow_url', 'recovery_url', 'testing_url', 'assets'
  ];
  if (!validDevice(device) || !exactKeys(release, keys)) return false;
  const versionPattern = /^v(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)-rc\.(?:0|[1-9]\d*)$/;
  const expectedTag = flavor === 'nss' ? `ram-test-nss-${release.version}` : `ram-test-${release.version}`;
  if (release.device_id !== device.id || release.device_name !== device.display_name ||
      release.flavor !== flavor || release.flavor_experimental !== device.flavors[flavor].experimental ||
      release.channel !== 'ram-test' || release.hardware_status !== 'unverified' ||
      release.production_ready !== false || release.ram_only !== true ||
      typeof release.version !== 'string' || !versionPattern.test(release.version) || release.tag !== expectedTag ||
      !validUtcTimestamp(release.published_at) ||
      release.browser_build_workflow_url !== device.browser_build_workflow_url ||
      release.recovery_url !== device.recovery_url || release.testing_url !== device.testing_url ||
      !validHttpsGitHubUrl(release.release_url, `/${REPOSITORY}/releases/tag/${expectedTag}`)) return false;

  const archive = `NexaWrt-${device.model}-${flavor}-${release.version}-verified-dist.tar.gz`;
  const expectedNames = {
    archive,
    checksum: `${archive}.sha256`,
    provenance_archive: 'archive.provenance.bundle.json',
    provenance_checksums: 'checksums.provenance.bundle.json',
    provenance_firmware: 'firmware.provenance.bundle.json',
    provenance_sbom: 'sbom.provenance.bundle.json'
  };
  if (!exactKeys(release.assets, Object.keys(expectedNames))) return false;
  return Object.entries(expectedNames).every(([key, expectedName]) => {
    const asset = release.assets[key];
    return exactKeys(asset, ['name', 'url', 'size']) && asset.name === expectedName &&
      Number.isInteger(asset.size) && asset.size > 0 &&
      validHttpsGitHubUrl(asset.url, `/${REPOSITORY}/releases/download/${expectedTag}/${expectedName}`);
  });
}

function versionTuple(version) {
  const match = /^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)-rc\.(0|[1-9]\d*)$/.exec(version);
  return match ? match.slice(1).map((part) => BigInt(part)) : null;
}

function compareVersions(left, right) {
  const leftParts = versionTuple(left);
  const rightParts = versionTuple(right);
  if (!leftParts || !rightParts) return 0;
  for (let index = 0; index < leftParts.length; index += 1) {
    if (leftParts[index] < rightParts[index]) return -1;
    if (leftParts[index] > rightParts[index]) return 1;
  }
  return 0;
}

function validReleaseGroup(group, flavor, device) {
  if (!exactKeys(group, ['latest', 'history']) || !Array.isArray(group.history) || group.history.length > 12) {
    return false;
  }
  if (group.history.length === 0) return group.latest === null;
  if (!validRelease(group.latest, flavor, device) || JSON.stringify(group.latest) !== JSON.stringify(group.history[0])) {
    return false;
  }
  const tags = new Set();
  let previous = null;
  for (const release of group.history) {
    if (!validRelease(release, flavor, device) || tags.has(release.tag)) return false;
    if (previous !== null && (release.published_at > previous.published_at ||
        (release.published_at === previous.published_at && compareVersions(release.version, previous.version) > 0))) {
      return false;
    }
    tags.add(release.tag);
    previous = release;
  }
  return true;
}

function vmExpectedNames(version, contractVersion) {
  const prefix = `NexaWrt-${VM_PLATFORM}-${version}`;
  const rawBios = `${prefix}-generic-ext4-combined.img.gz`;
  if (contractVersion === 1) {
    return {
      image: rawBios,
      image_checksum: `${rawBios}.sha256`,
      manifest: `${rawBios.slice(0, -'.img.gz'.length)}.manifest`,
      artifact_labels: 'artifact-labels.env',
      readme: 'README-VM.txt',
      smoke_report: 'smoke-report.txt',
      checksums: 'SHA256SUMS',
      provenance_image: 'image.provenance.bundle.json',
      provenance_checksums: 'checksums.provenance.bundle.json'
    };
  }
  if (contractVersion !== 2) return null;
  const variants = {
    raw_bios: rawBios,
    iso_bios: `${prefix}-generic-image.iso`,
    iso_efi: `${prefix}-generic-image-efi.iso`,
    vmdk_bios: `${prefix}-generic-ext4-combined.vmdk`,
    vmdk_efi: `${prefix}-generic-ext4-combined-efi.vmdk`
  };
  const names = {};
  for (const variant of VM_VARIANTS) {
    names[variant] = variants[variant];
    names[`${variant}_checksum`] = `${variants[variant]}.sha256`;
  }
  return Object.assign(names, {
    manifest: `${prefix}-generic.manifest`,
    artifact_labels: 'artifact-labels.env',
    readme: 'README-VM.txt',
    smoke_report: 'smoke-report.txt',
    checksums: 'SHA256SUMS',
    provenance_raw_bios: 'raw-bios.provenance.bundle.json',
    provenance_iso_bios: 'iso-bios.provenance.bundle.json',
    provenance_iso_efi: 'iso-efi.provenance.bundle.json',
    provenance_vmdk_bios: 'vmdk-bios.provenance.bundle.json',
    provenance_vmdk_efi: 'vmdk-efi.provenance.bundle.json',
    provenance_checksums: 'checksums.provenance.bundle.json'
  });
}

function validVmValidation(value, contractVersion) {
  const variants = contractVersion === 1 ? ['raw_bios'] : VM_VARIANTS;
  return exactKeys(value, ['qemu', 'esxi']) && value.esxi === 'not-tested' &&
    exactKeys(value.qemu, variants) && variants.every((variant) => value.qemu[variant] === 'runtime-pass');
}

function validVmRelease(release, schemaVersion = null) {
  const inferredSchema = schemaVersion ?? (release && Object.prototype.hasOwnProperty.call(release, 'contract_version') ? 4 : 3);
  const legacyKeys = [
    'platform', 'artifact_class', 'vm_only', 'not_ax9000_firmware', 'hardware_validation',
    'nss_validation', 'qemu_validated', 'ssh_default', 'version', 'tag', 'published_at',
    'release_url', 'browser_build_workflow_url', 'docs_url', 'assets'
  ];
  const v4Keys = [
    'platform', 'artifact_class', 'contract_version', 'release_contract', 'vm_only',
    'not_ax9000_firmware', 'hardware_validation', 'nss_validation', 'qemu_validated',
    'esxi_validation', 'ssh_default', 'validation', 'version', 'tag', 'published_at',
    'release_url', 'browser_build_workflow_url', 'docs_url', 'assets'
  ];
  if (inferredSchema === 3) {
    if (!exactKeys(release, legacyKeys)) return false;
  } else if (inferredSchema === 4) {
    if (!exactKeys(release, v4Keys)) return false;
  } else {
    return false;
  }
  const versionPattern = /^v(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)-rc\.(?:0|[1-9]\d*)$/;
  const expectedTag = `vm-${VM_PLATFORM}-${release.version}`;
  const contractVersion = inferredSchema === 3 ? 1 : release.contract_version;
  const expectedClass = contractVersion === 1 ? 'VM_DISTRIBUTION_IMAGE' : 'VM_DISTRIBUTION_SET';
  if ((contractVersion !== 1 && contractVersion !== 2) || release.platform !== VM_PLATFORM ||
      release.artifact_class !== expectedClass || release.vm_only !== true ||
      release.not_ax9000_firmware !== true || release.hardware_validation !== false ||
      release.nss_validation !== false || release.qemu_validated !== true || release.ssh_default !== 'disabled' ||
      typeof release.version !== 'string' || !versionPattern.test(release.version) || release.tag !== expectedTag ||
      !validUtcTimestamp(release.published_at) || release.browser_build_workflow_url !== VM_RELEASE_WORKFLOW_URL ||
      release.docs_url !== VM_DOCS_URL ||
      !validHttpsGitHubUrl(release.release_url, `/${REPOSITORY}/releases/tag/${expectedTag}`)) return false;
  if (inferredSchema === 4 && (release.release_contract !== `vm-x86_64/v${contractVersion}` ||
      release.esxi_validation !== 'not-tested' || !validVmValidation(release.validation, contractVersion))) return false;

  const expectedNames = vmExpectedNames(release.version, contractVersion);
  if (!expectedNames || !exactKeys(release.assets, Object.keys(expectedNames))) return false;
  return Object.entries(expectedNames).every(([key, expectedName]) => {
    const asset = release.assets[key];
    const expectedAssetKeys = inferredSchema === 4 ? ['name', 'url', 'size', 'sha256'] : ['name', 'url', 'size'];
    return exactKeys(asset, expectedAssetKeys) && asset.name === expectedName &&
      Number.isInteger(asset.size) && asset.size > 0 &&
      (inferredSchema !== 4 || /^[0-9a-f]{64}$/.test(asset.sha256)) &&
      validHttpsGitHubUrl(asset.url, `/${REPOSITORY}/releases/download/${expectedTag}/${expectedName}`);
  });
}

function validVmReleaseGroup(group, schemaVersion = null) {
  if (!exactKeys(group, ['latest', 'history']) || !Array.isArray(group.history) || group.history.length > 12) {
    return false;
  }
  if (group.history.length === 0) return group.latest === null;
  if (!validVmRelease(group.latest, schemaVersion) || JSON.stringify(group.latest) !== JSON.stringify(group.history[0])) return false;
  const tags = new Set();
  let previous = null;
  for (const release of group.history) {
    if (!validVmRelease(release, schemaVersion) || tags.has(release.tag)) return false;
    if (previous !== null && (release.published_at > previous.published_at ||
        (release.published_at === previous.published_at && compareVersions(release.version, previous.version) > 0))) {
      return false;
    }
    tags.add(release.tag);
    previous = release;
  }
  return true;
}

function formatDate(timestamp) {
  const date = new Date(timestamp);
  if (Number.isNaN(date.getTime())) return '—';
  return new Intl.DateTimeFormat(['zh-CN', 'en'], {
    year: 'numeric', month: 'short', day: '2-digit', timeZone: 'UTC'
  }).format(date);
}

function renderDevice(device) {
  document.querySelector('[data-device-field="name"]').textContent = device.display_name;
  document.querySelector('[data-device-field="target"]').textContent = `${device.target} / ${device.subtarget}`;
  document.querySelector('[data-device-field="status"]').textContent = '尚未真机验证 · 非生产 · RAM candidate only';
  const buildLink = document.querySelector('#browser-build-link');
  buildLink.href = device.browser_build_workflow_url;
  buildLink.hidden = false;
  const docs = document.querySelector('#device-doc-links');
  docs.replaceChildren(
    makeLink('恢复指南 / Recovery ↗', device.recovery_url),
    makeLink('测试门禁 / Testing ↗', device.testing_url)
  );
}

function showUnavailable(card) {
  const downloads = card.querySelector('[data-field="downloads"]');
  const message = document.createElement('span');
  message.className = 'unavailable';
  message.textContent = '暂无完整已验证资产 / No complete verified release yet';
  downloads.replaceChildren(message);
  card.querySelector('[data-field="version"]').textContent = '—';
  const date = card.querySelector('[data-field="date"]');
  date.textContent = '等待数据';
  date.dateTime = '';
  card.querySelector('[data-field="provenance"]').replaceChildren();
  card.querySelector('details').hidden = true;
  card.querySelector('[data-field="support-links"]').replaceChildren();
  const releaseUrl = card.querySelector('[data-field="release-url"]');
  releaseUrl.removeAttribute('href');
  releaseUrl.hidden = true;
}

function resetAxUi() {
  for (const flavor of FLAVORS) showUnavailable(document.querySelector(`[data-flavor="${flavor}"]`));
  renderHistory({}, null);
  const buildLink = document.querySelector('#browser-build-link');
  buildLink.removeAttribute('href');
  buildLink.hidden = true;
  document.querySelector('#device-doc-links').replaceChildren();
  document.querySelector('[data-device-field="name"]').textContent = 'AX9000 目录不可用 / Unavailable';
  document.querySelector('[data-device-field="target"]').textContent = '—';
  document.querySelector('[data-device-field="status"]').textContent = 'AX9000 下载与构建入口已禁用 / Disabled';
}

function resetVmHistoryActions() {
  const actions = document.querySelector('#vm-history-actions');
  if (!actions) return;
  actions.replaceChildren();
  actions.hidden = true;
}

function renderVmHistoryActions(release) {
  const actions = document.querySelector('#vm-history-actions');
  if (!actions) return;
  if (!validVmRelease(release)) {
    resetVmHistoryActions();
    return;
  }
  actions.replaceChildren(makeLink('浏览器云编译 VM ↗', release.browser_build_workflow_url));
  actions.hidden = false;
}

function resetVmUi() {
  showVmUnavailable();
  renderVmHistory(null);
  resetVmHistoryActions();
}

function resetReleaseUi() {
  resetAxUi();
  resetVmUi();
}

function renderCard(flavor, release, device) {
  const card = document.querySelector(`[data-flavor="${flavor}"]`);
  if (!card) return;
  if (!validRelease(release, flavor, device)) {
    showUnavailable(card);
    return;
  }

  card.querySelector('[data-field="version"]').textContent = release.version;
  const date = card.querySelector('[data-field="date"]');
  date.textContent = formatDate(release.published_at);
  date.dateTime = release.published_at;
  card.querySelector('[data-field="downloads"]').replaceChildren(
    makeLink('下载已验证归档 ↓', release.assets.archive.url),
    makeLink('SHA-256', release.assets.checksum.url)
  );
  card.querySelector('[data-field="provenance"]').replaceChildren(
    ...Object.entries(PROVENANCE_LABELS).map(([key, label]) => makeLink(label, release.assets[key].url))
  );
  card.querySelector('[data-field="support-links"]').replaceChildren(
    makeLink('浏览器云编译 ↗', release.browser_build_workflow_url),
    makeLink('恢复指南 ↗', release.recovery_url),
    makeLink('测试要求 ↗', release.testing_url)
  );
  const releaseUrl = card.querySelector('[data-field="release-url"]');
  releaseUrl.href = release.release_url;
  releaseUrl.hidden = false;
  card.querySelector('details').hidden = false;
}

function renderHistory(flavorData, device) {
  const history = document.querySelector('#release-history');
  const rows = [];
  for (const flavor of FLAVORS) {
    const releases = Array.isArray(flavorData[flavor]?.history) ? flavorData[flavor].history : [];
    for (const release of releases) {
      if (validRelease(release, flavor, device)) rows.push({ flavor, release });
    }
  }
  rows.sort((left, right) => {
    const byTime = right.release.published_at.localeCompare(left.release.published_at);
    return byTime || compareVersions(right.release.version, left.release.version);
  });
  if (!rows.length) {
    const empty = document.createElement('p');
    empty.className = 'empty-state';
    empty.textContent = '暂无完整已验证历史版本 / No complete verified history';
    history.replaceChildren(empty);
    return;
  }
  const fragment = document.createDocumentFragment();
  for (const { flavor, release } of rows) {
    const row = document.createElement('article');
    row.className = 'history-item';
    const flavorLabel = document.createElement('span');
    flavorLabel.className = `history-flavor ${flavor}`;
    flavorLabel.textContent = release.flavor_experimental ? 'NSS · EXP' : 'OFFICIAL';
    const tag = document.createElement('strong');
    tag.className = 'history-tag';
    tag.textContent = release.tag;
    const date = document.createElement('time');
    date.dateTime = release.published_at;
    date.textContent = formatDate(release.published_at);
    row.append(flavorLabel, tag, date, makeLink('Archive ↓', release.assets.archive.url));
    fragment.append(row);
  }
  history.replaceChildren(fragment);
}

function showVmUnavailable() {
  const card = document.querySelector(`[data-vm-platform="${VM_PLATFORM}"]`);
  if (!card) return;
  const message = document.createElement('span');
  message.className = 'unavailable';
  message.textContent = '暂无完整已验证虚拟机镜像 / No complete verified VM image yet';
  card.querySelector('[data-vm-field="downloads"]').replaceChildren(message);
  card.querySelector('[data-vm-field="version"]').textContent = '—';
  const date = card.querySelector('[data-vm-field="date"]');
  date.textContent = '等待数据';
  date.dateTime = '';
  card.querySelector('[data-vm-field="provenance"]').replaceChildren();
  card.querySelector('[data-vm-field="support-links"]').replaceChildren();
  const releaseUrl = card.querySelector('[data-vm-field="release-url"]');
  releaseUrl.removeAttribute('href');
  releaseUrl.hidden = true;
  card.querySelector('details').hidden = true;
}

function renderVmCard(release) {
  const card = document.querySelector(`[data-vm-platform="${VM_PLATFORM}"]`);
  if (!card) return;
  if (!validVmRelease(release)) {
    showVmUnavailable();
    return;
  }
  card.querySelector('[data-vm-field="version"]').textContent = release.version;
  const date = card.querySelector('[data-vm-field="date"]');
  date.textContent = formatDate(release.published_at);
  date.dateTime = release.published_at;
  const contractVersion = release.contract_version ?? 1;
  const downloadKeys = contractVersion === 2 ? VM_VARIANTS : ['image'];
  const downloadLabels = contractVersion === 2 ? VM_DOWNLOAD_LABELS : { image: '下载 x86_64 RAW 镜像 ↓' };
  card.querySelector('[data-vm-field="downloads"]').replaceChildren(
    ...downloadKeys.map((key) => makeLink(downloadLabels[key], release.assets[key].url, 'vm-download')),
    makeLink('SHA256SUMS', release.assets.checksums.url, 'vm-support-download'),
    makeLink('Manifest', release.assets.manifest.url, 'vm-support-download')
  );
  const provenanceLabels = contractVersion === 2 ? VM_V2_PROVENANCE_LABELS : VM_V1_PROVENANCE_LABELS;
  card.querySelector('[data-vm-field="provenance"]').replaceChildren(
    ...Object.entries(provenanceLabels).map(([key, label]) => makeLink(label, release.assets[key].url))
  );
  card.querySelector('[data-vm-field="support-links"]').replaceChildren(
    makeLink('浏览器云编译 VM ↗', release.browser_build_workflow_url),
    makeLink('VM 文档 ↗', release.docs_url)
  );
  const releaseUrl = card.querySelector('[data-vm-field="release-url"]');
  releaseUrl.href = release.release_url;
  releaseUrl.hidden = false;
  card.querySelector('details').hidden = false;
}

function renderVmHistory(group) {
  const history = document.querySelector('#vm-history');
  if (!history) return;
  const releases = Array.isArray(group?.history) ? group.history.filter(validVmRelease) : [];
  if (!releases.length) {
    const empty = document.createElement('p');
    empty.className = 'empty-state';
    empty.textContent = '暂无完整已验证 VM 历史版本 / No verified VM history';
    history.replaceChildren(empty);
    return;
  }
  const fragment = document.createDocumentFragment();
  for (const release of releases) {
    const row = document.createElement('article');
    row.className = 'history-item vm-history-item';
    const flavorLabel = document.createElement('span');
    flavorLabel.className = 'history-flavor vm';
    flavorLabel.textContent = 'x86_64 VM';
    const tag = document.createElement('strong');
    tag.className = 'history-tag';
    tag.textContent = release.tag;
    const date = document.createElement('time');
    date.dateTime = release.published_at;
    date.textContent = formatDate(release.published_at);
        const primaryAsset = release.contract_version === 2 ? release.assets.raw_bios : release.assets.image;
    row.append(flavorLabel, tag, date, makeLink('RAW ↓', primaryAsset.url));
    fragment.append(row);
  }
  history.replaceChildren(fragment);
}


async function loadReleases() {
  const status = document.querySelector('#data-status');
  try {
    const response = await fetch('releases.json', { cache: 'no-store', credentials: 'same-origin' });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const data = await response.json();
    if (!exactKeys(data, ['schema_version', 'repository', 'generated_at', 'devices', 'flavors', 'virtual_images']) ||
        !([3, 4].includes(data.schema_version)) || data.repository !== REPOSITORY || !validUtcTimestamp(data.generated_at) ||
        !data.devices || typeof data.devices !== 'object' || Array.isArray(data.devices) ||
        !data.flavors || typeof data.flavors !== 'object' || Array.isArray(data.flavors) ||
        !data.virtual_images || typeof data.virtual_images !== 'object' || Array.isArray(data.virtual_images)) {
      throw new Error('unexpected release index schema');
    }

    const device = exactKeys(data.devices, [DEVICE_ID]) ? data.devices[DEVICE_ID] : null;
    const axValid = validDevice(device) && exactKeys(data.flavors, FLAVORS) &&
      FLAVORS.every((flavor) => validReleaseGroup(data.flavors[flavor], flavor, device));
    if (axValid) {
      renderDevice(device);
      for (const flavor of FLAVORS) renderCard(flavor, data.flavors[flavor].latest, device);
      renderHistory(data.flavors, device);
    } else {
      resetAxUi();
      console.error('Invalid AX9000 catalog; VM catalog remains independently eligible.');
    }

    const vmGroup = exactKeys(data.virtual_images, [VM_PLATFORM])
      ? data.virtual_images[VM_PLATFORM]
      : null;
    const vmValid = validVmReleaseGroup(vmGroup, data.schema_version);
    if (vmValid) {
      renderVmCard(vmGroup.latest);
      renderVmHistory(vmGroup);
      renderVmHistoryActions(vmGroup.latest);
    } else {
      resetVmUi();
      console.error('Invalid VM release group; AX9000 catalog remains independently eligible.');
    }

    if (!axValid && !vmValid) status.classList.add('error');
    else status.classList.remove('error');
    if (!axValid && !vmValid) {
      status.textContent = 'AX9000 与 VM 目录均无效；下载与构建入口已禁用。 / Both catalogs invalid; disabled.';
    } else if (!axValid) {
      status.textContent = 'VM 目录已验证；AX9000 目录无效并已独立禁用。 / VM verified; AX9000 disabled.';
    } else if (!vmValid) {
      status.textContent = 'AX9000 目录已验证；VM 目录无效并已独立禁用。 / AX9000 verified; VM disabled.';
    } else {
      status.textContent = data.generated_at === '1970-01-01T00:00:00Z'
        ? '设备目录已验证；尚未发布版本 / Device catalog verified; no release published yet'
        : `索引更新 / Index generated: ${formatDate(data.generated_at)} UTC`;
    }
  } catch (error) {
    resetReleaseUi();
    status.classList.add('error');
    status.textContent = '设备或发布索引暂不可用；已禁用下载与构建入口。 / Catalog unavailable; downloads and builds disabled.';
    console.error('Unable to load the allowlisted device/release index:', error);
  }
}

const TIMEZONES = {
  'Asia/Shanghai': 'CST-8',
  'Asia/Tokyo': 'JST-9',
  'Asia/Singapore': '<+08>-8',
  'Europe/London': 'GMT0BST,M3.5.0/1,M10.5.0',
  'Europe/Berlin': 'CET-1CEST,M3.5.0,M10.5.0/3',
  'America/New_York': 'EST5EDT,M3.2.0,M11.1.0',
  'America/Los_Angeles': 'PST8PDT,M3.2.0,M11.1.0',
  'Australia/Sydney': 'AEST-10AEDT,M10.1.0,M4.1.0/3',
  'UTC': 'UTC0'
};
const COUNTRIES = new Set(['CN', 'US', 'GB', 'DE', 'JP', 'AU', 'SG']);

function isPrivateIPv4(value) {
  const parts = value.split('.');
  if (parts.length !== 4 || parts.some((part) => !/^(?:0|[1-9]\d{0,2})$/.test(part))) return false;
  const octets = parts.map(Number);
  if (octets.some((part) => part > 255)) return false;
  const [a, b, , d] = octets;
  const privateRange = a === 10 || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168);
  return privateRange && d !== 0 && d !== 255;
}

const CONFIG_OUTPUT_PLACEHOLDER = '# 配置尚未通过验证 / Configuration not validated';
const CONFIG_FIELD_NAMES = ['hostname', 'lan-ip', 'timezone', 'country'];

function invalidateConfigSnippet(form) {
  const error = document.querySelector('#config-error');
  const output = document.querySelector('#config-output');
  const copyButton = document.querySelector('#copy-snippet');

  output.textContent = CONFIG_OUTPUT_PLACEHOLDER;
  copyButton.disabled = true;
  copyButton.textContent = '复制 / Copy';
  error.textContent = '';
  error.hidden = true;
  for (const name of CONFIG_FIELD_NAMES) form.elements[name].removeAttribute('aria-invalid');
}

function generateSnippet(event) {
  event.preventDefault();
  const form = event.currentTarget;
  invalidateConfigSnippet(form);

  const error = document.querySelector('#config-error');
  const output = document.querySelector('#config-output');
  const copyButton = document.querySelector('#copy-snippet');

  const hostname = form.elements.hostname.value.trim().toLowerCase();
  const lanIp = form.elements['lan-ip'].value.trim();
  const zonename = form.elements.timezone.value;
  const country = form.elements.country.value;
  const hostnamePattern = /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/;

  let problem = '';
  let invalidField = '';
  if (!hostnamePattern.test(hostname)) {
    problem = '主机名必须为 1–63 个字母、数字或中划线，且不能以中划线开头或结尾。';
    invalidField = 'hostname';
  } else if (!isPrivateIPv4(lanIp)) {
    problem = 'LAN IP 必须是有效的 RFC1918 私有 IPv4 主机地址。';
    invalidField = 'lan-ip';
  } else if (!Object.hasOwn(TIMEZONES, zonename)) {
    problem = '请选择列表中的时区。';
    invalidField = 'timezone';
  } else if (!COUNTRIES.has(country)) {
    problem = '请选择列表中的无线国家码。';
    invalidField = 'country';
  }

  if (problem) {
    form.elements[invalidField].setAttribute('aria-invalid', 'true');
    error.textContent = problem;
    error.hidden = false;
    return;
  }

  const snippet = `# NexaWrt RAM-session configuration — review before running
# Volatile runtime settings only; this does not modify or rebuild the image.
uci -q batch <<'NEXAWRT_SAFE_CONFIG'
set system.@system[0].hostname='${hostname}'
set system.@system[0].zonename='${zonename}'
set system.@system[0].timezone='${TIMEZONES[zonename]}'
set network.lan.ipaddr='${lanIp}'
set wireless.radio0.country='${country}'
set wireless.radio1.country='${country}'
set wireless.radio2.country='${country}'
commit system
commit network
commit wireless
NEXAWRT_SAFE_CONFIG

/etc/init.d/system reload
/etc/init.d/network reload
wifi reload
`;
  output.textContent = snippet;
  copyButton.disabled = false;
}

async function copySnippet() {
  const button = document.querySelector('#copy-snippet');
  try {
    await navigator.clipboard.writeText(document.querySelector('#config-output').textContent);
    button.textContent = '已复制 / Copied';
    window.setTimeout(() => { button.textContent = '复制 / Copy'; }, 1800);
  } catch {
    button.textContent = '请手动复制 / Select manually';
  }
}

const configForm = document.querySelector('#config-form');
configForm.addEventListener('submit', generateSnippet);
configForm.addEventListener('input', () => invalidateConfigSnippet(configForm));
configForm.addEventListener('change', () => invalidateConfigSnippet(configForm));
document.querySelector('#copy-snippet').addEventListener('click', copySnippet);
loadReleases();
