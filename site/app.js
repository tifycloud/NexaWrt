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
const CUSTOM_BUILD_WORKFLOW_FILE = 'custom-build.yml';
const CUSTOM_BUILD_WORKFLOW_URL = `https://github.com/${REPOSITORY}/actions/workflows/${CUSTOM_BUILD_WORKFLOW_FILE}`;
const COMPONENT_CATALOG_URL = 'components/catalog.json';
const PACKAGE_CATALOG_URL = 'components/package-catalog.json';
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
  const rcVersionPattern = /^v(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)-rc\.(?:0|[1-9]\d*)$/;
  const stableVersionPattern = /^v(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)$/;
  const expectedTag = flavor === 'nss' ? `ram-test-nss-${release.version}` : `ram-test-${release.version}`;
  if (release.device_id !== device.id || release.device_name !== device.display_name ||
      release.flavor !== flavor || release.flavor_experimental !== device.flavors[flavor].experimental ||
      release.channel !== 'ram-test' || release.hardware_status !== 'unverified' ||
      release.production_ready !== false || release.ram_only !== true ||
      typeof release.version !== 'string' || (!rcVersionPattern.test(release.version) && !stableVersionPattern.test(release.version)) || release.tag !== expectedTag ||
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
  const match = /^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-rc\.(0|[1-9]\d*))?$/.exec(version);
  return match ? [BigInt(match[1]), BigInt(match[2]), BigInt(match[3]), match[4] === undefined ? 1000000000n : BigInt(match[4])] : null;
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

function validVmValidation(value, contractVersion, expectedEsxi = 'not-tested') {
  const variants = contractVersion === 1 ? ['raw_bios'] : VM_VARIANTS;
  return exactKeys(value, ['qemu', 'esxi']) && value.esxi === expectedEsxi &&
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
  const rcVersionPattern = /^v(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)-rc\.(?:0|[1-9]\d*)$/;
  const stableVersionPattern = /^v(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)$/;
  const expectedTag = `vm-${VM_PLATFORM}-${release.version}`;
  const contractVersion = inferredSchema === 3 ? 1 : release.contract_version;
  const expectedClass = contractVersion === 1 ? 'VM_DISTRIBUTION_IMAGE' : 'VM_DISTRIBUTION_SET';
  if ((contractVersion !== 1 && contractVersion !== 2) || release.platform !== VM_PLATFORM ||
      release.artifact_class !== expectedClass || release.vm_only !== true ||
      release.not_ax9000_firmware !== true || release.hardware_validation !== false ||
      release.nss_validation !== false || release.qemu_validated !== true || release.ssh_default !== 'disabled' ||
      typeof release.version !== 'string' || (!rcVersionPattern.test(release.version) && !stableVersionPattern.test(release.version)) || release.tag !== expectedTag ||
      !validUtcTimestamp(release.published_at) || release.browser_build_workflow_url !== VM_RELEASE_WORKFLOW_URL ||
      release.docs_url !== VM_DOCS_URL ||
      !validHttpsGitHubUrl(release.release_url, `/${REPOSITORY}/releases/tag/${expectedTag}`)) return false;
  const stable = stableVersionPattern.test(release.version);
  const expectedEsxi = stable ? 'validated' : 'not-tested';
  if (stable && contractVersion !== 2) return false;
  if (inferredSchema === 4 && (release.release_contract !== `vm-x86_64/v${contractVersion}` ||
      release.esxi_validation !== expectedEsxi || !validVmValidation(release.validation, contractVersion, expectedEsxi))) return false;

  let assetVersion = release.version;
  if (stable) {
    const rawName = release.assets?.raw_bios?.name;
    const match = typeof rawName === 'string' ? /^NexaWrt-x86_64-(v(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)-rc\.(?:0|[1-9]\d*))-generic-ext4-combined\.img\.gz$/.exec(rawName) : null;
    if (!match || match[1].split('-rc.', 1)[0] !== release.version) return false;
    assetVersion = match[1];
  }
  const expectedNames = vmExpectedNames(assetVersion, contractVersion);
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

function renderVmHistory(group, schemaVersion = null) {
  const history = document.querySelector('#vm-history');
  if (!history) return;
  const releases = Array.isArray(group?.history) ? group.history.filter((release) => validVmRelease(release, schemaVersion)) : [];
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
      renderVmHistory(vmGroup, data.schema_version);
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


const COMPONENT_CATALOG_KEYS = [
  'schema_version', 'catalog_version', 'max_selected_components', 'targets', 'categories', 'components'
];
const COMPONENT_TARGET_KEYS = ['id', 'display_name', 'openwrt_target', 'openwrt_subtarget', 'profile'];
const COMPONENT_CATEGORY_KEYS = ['id', 'title', 'description', 'order'];
const COMPONENT_KEYS = [
  'id', 'name', 'description', 'category', 'packages', 'depends', 'conflicts',
  'supported_targets', 'default_for'
];
const PACKAGE_CATALOG_ROOT_KEYS = ['schema_version', 'catalog_version', 'openwrt_version', 'shards'];
const PACKAGE_CATALOG_SHARD_INDEX_KEYS = [
  'target', 'flavor', 'path', 'sha256', 'package_count', 'selectable_count', 'sources'
];
const OFFICIAL_PACKAGE_SOURCE_KEYS = ['feed', 'url', 'sha256'];
const COMMUNITY_PACKAGE_SOURCE_KEYS = ['feed', 'url', 'sha256', 'metadata_format', 'metadata_signed', 'candidate_repository', 'candidate_commit', 'catalog_sha256'];
const PACKAGE_CATALOG_SHARD_KEYS = ['schema_version', 'catalog_version', 'target', 'flavor', 'packages'];
const PACKAGE_RECORD_KEYS = [
  'id', 'package', 'version', 'description', 'feed', 'source', 'installed_size', 'category',
  'arch', 'risk', 'selectable', 'blocked_reason'
];
const SAFE_COMPONENT_ID = /^[a-z0-9][a-z0-9_-]{0,63}$/;
const SAFE_OPENWRT_TOKEN = /^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$/;
const SAFE_CATALOG_VERSION = /^\d{4}\.\d{2}\.\d{2}(?:\.\d+)?$/;
const SAFE_OPENWRT_VERSION = /^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$/;
const SAFE_SHA256 = /^[a-f0-9]{64}$/;
const SAFE_SHARD_PATH = /^(?:components\/)?packages\/[A-Za-z0-9_.-]+\.json$/;
const KIDDIN9_PACKAGES_URL = 'https://dl.openwrt.ai/releases/25.12/packages/aarch64_cortex-a53/kiddin9/Packages.gz';
const KIDDIN9_PACKAGES_SHA256 = 'ce97a429f7fcd414a22b3ad701118d5299319a84add12c26d401216184c8bd04';
const KIDDIN9_CANDIDATE_REPOSITORY = 'https://github.com/kiddin9/op-packages.git';
const KIDDIN9_CANDIDATE_COMMIT = '9f2092b4f204fc9948226d9a3f5166b69976af48';
const KIDDIN9_CATALOG_SHA256 = '4b14b36b0c9839f81bb6a56ffc1ac94384603c7a9c93e7f63ac48ffc4c699292';
const REQUIRED_COMPONENT_TARGETS = new Set(['x86_64', 'xiaomi_ax9000']);
const PACKAGE_RISKS = new Set(['standard', 'advanced', 'system']);
const PACKAGE_ARCHITECTURES = {
  'x86_64/official': new Set(['x86_64', 'noarch']),
  'xiaomi_ax9000/official': new Set(['aarch64_cortex-a53', 'noarch']),
  'xiaomi_ax9000/nss': new Set(['noarch'])
};
const MAX_CATALOG_ITEMS = 256;
const MAX_PACKAGE_SHARDS = 32;
const MAX_PACKAGE_RECORDS = 20000;
const MAX_PACKAGE_RESULTS = 100;
const CUSTOM_BUILD_FLAVORS = {
  official: { id: 'official', label: 'Official · 官方' },
  nss: { id: 'nss', label: 'NSS · 实验性' }
};
let componentCatalog = null;
let packageCatalogRoot = null;
let currentPackageShard = null;
let currentPackageMap = new Map();
let currentPackageSearchTerms = new Map();
const verifiedPackageShardCache = new Map();
let requestedComponentIds = new Set();
let resolvedComponentIds = new Set();
let componentRequestSequence = 0;
let packageShardRequestSequence = 0;
let componentSearchTimer = null;

function validCatalogText(value, maxLength, allowEmpty = false) {
  return typeof value === 'string' && value === value.trim() && value.length <= maxLength &&
    (allowEmpty || value.length > 0) && !/[\u0000-\u001f\u007f]/.test(value);
}

function validComponentId(value) {
  return typeof value === 'string' && SAFE_COMPONENT_ID.test(value);
}

function uniqueStrings(values, validator, maxItems = 64, allowEmpty = true) {
  return Array.isArray(values) && (allowEmpty || values.length > 0) && values.length <= maxItems &&
    values.every((value) => validator(value)) && new Set(values).size === values.length;
}

function hasDependencyCycle(componentsById) {
  const visiting = new Set();
  const visited = new Set();
  function visit(id) {
    if (visiting.has(id)) return true;
    if (visited.has(id)) return false;
    visiting.add(id);
    for (const dependency of componentsById.get(id).depends) {
      if (visit(dependency)) return true;
    }
    visiting.delete(id);
    visited.add(id);
    return false;
  }
  return [...componentsById.keys()].some(visit);
}

function validateComponentCatalog(catalog) {
  if (!exactKeys(catalog, COMPONENT_CATALOG_KEYS) || catalog.schema_version !== 1 ||
      !SAFE_CATALOG_VERSION.test(catalog.catalog_version) ||
      !Number.isInteger(catalog.max_selected_components) || catalog.max_selected_components < 1 ||
      catalog.max_selected_components > 64 ||
      !Array.isArray(catalog.targets) || catalog.targets.length < 1 || catalog.targets.length > 32 ||
      !Array.isArray(catalog.categories) || catalog.categories.length < 1 || catalog.categories.length > 64 ||
      !Array.isArray(catalog.components) || catalog.components.length < 1 ||
      catalog.components.length > MAX_CATALOG_ITEMS) return false;

  const targetIds = new Set();
  for (const target of catalog.targets) {
    if (!exactKeys(target, COMPONENT_TARGET_KEYS) || !validComponentId(target.id) ||
        !validCatalogText(target.display_name, 80) || !SAFE_OPENWRT_TOKEN.test(target.openwrt_target) ||
        !SAFE_OPENWRT_TOKEN.test(target.openwrt_subtarget) || !SAFE_OPENWRT_TOKEN.test(target.profile) ||
        targetIds.has(target.id)) return false;
    targetIds.add(target.id);
  }
  if (![...REQUIRED_COMPONENT_TARGETS].every((id) => targetIds.has(id))) return false;

  const categoryIds = new Set();
  const categoryOrders = new Set();
  for (const category of catalog.categories) {
    if (!exactKeys(category, COMPONENT_CATEGORY_KEYS) || !validComponentId(category.id) ||
        !validCatalogText(category.title, 80) || !validCatalogText(category.description, 240) ||
        !Number.isInteger(category.order) || category.order < 0 || category.order > 10000 ||
        categoryIds.has(category.id) || categoryOrders.has(category.order)) return false;
    categoryIds.add(category.id);
    categoryOrders.add(category.order);
  }

  const componentsById = new Map();
  for (const component of catalog.components) {
    if (!exactKeys(component, COMPONENT_KEYS) || !validComponentId(component.id) ||
        !validCatalogText(component.name, 80) || !validCatalogText(component.description, 240) ||
        !categoryIds.has(component.category) ||
        !uniqueStrings(component.packages, (value) => typeof value === 'string' && SAFE_OPENWRT_TOKEN.test(value), 128, false) ||
        !uniqueStrings(component.depends, validComponentId) ||
        !uniqueStrings(component.conflicts, validComponentId) ||
        !uniqueStrings(component.supported_targets, validComponentId, 32, false) ||
        !uniqueStrings(component.default_for, validComponentId, 32) ||
        !component.supported_targets.every((id) => targetIds.has(id)) ||
        !component.default_for.every((id) => component.supported_targets.includes(id)) ||
        component.depends.includes(component.id) || component.conflicts.includes(component.id) ||
        componentsById.has(component.id)) return false;
    componentsById.set(component.id, component);
  }
  for (const component of catalog.components) {
    if (![...component.depends, ...component.conflicts].every((id) => componentsById.has(id))) return false;
    if (!component.conflicts.every((id) => componentsById.get(id).conflicts.includes(component.id))) return false;
  }
  return !hasDependencyCycle(componentsById);
}

function validOfficialSourceUrl(value) {
  if (!validCatalogText(value, 500)) return false;
  try {
    const url = new URL(value);
    if (url.protocol !== 'https:' || url.username || url.password || url.port || url.hash) return false;
    if (url.hostname === 'downloads.openwrt.org' || url.hostname === 'git.openwrt.org') return true;
    return url.hostname === 'github.com' && url.pathname.startsWith('/openwrt/');
  } catch {
    return false;
  }
}

function validPackageShardPath(value) {
  return typeof value === 'string' && value.length <= 240 && SAFE_SHARD_PATH.test(value) &&
    !value.includes('..') && !value.includes('//');
}

function packageShardFetchUrl(path) {
  return path.startsWith('components/') ? path : `components/${path}`;
}

function validatePackageCatalogRoot(root, catalog) {
  if (!exactKeys(root, PACKAGE_CATALOG_ROOT_KEYS) || root.schema_version !== 2 ||
      root.catalog_version !== catalog.catalog_version || !SAFE_CATALOG_VERSION.test(root.catalog_version) ||
      !SAFE_OPENWRT_VERSION.test(root.openwrt_version) || !Array.isArray(root.shards) ||
      root.shards.length < 1 || root.shards.length > MAX_PACKAGE_SHARDS) return false;
  const targetIds = new Set(catalog.targets.map((target) => target.id));
  const shardKeys = new Set();
  for (const shard of root.shards) {
    if (!exactKeys(shard, PACKAGE_CATALOG_SHARD_INDEX_KEYS) || !targetIds.has(shard.target) ||
        !Object.hasOwn(CUSTOM_BUILD_FLAVORS, shard.flavor) ||
        !flavorsForTarget(shard.target).some((flavor) => flavor.id === shard.flavor) ||
        !validPackageShardPath(shard.path) || !SAFE_SHA256.test(shard.sha256) ||
        !Number.isInteger(shard.package_count) || shard.package_count < 0 || shard.package_count > MAX_PACKAGE_RECORDS ||
        !Number.isInteger(shard.selectable_count) || shard.selectable_count < 0 ||
        shard.selectable_count > shard.package_count || !Array.isArray(shard.sources) ||
        shard.sources.length < 1 || shard.sources.length > 16) return false;
    const key = `${shard.target}/${shard.flavor}`;
    if (shardKeys.has(key)) return false;
    shardKeys.add(key);
    const sourceFeeds = new Set();
    for (const source of shard.sources) {
      const officialSource = source.feed !== 'kiddin9';
      if (!validComponentId(source.feed) || !SAFE_SHA256.test(source.sha256) || sourceFeeds.has(source.feed)) return false;
      if (officialSource) {
        if (!exactKeys(source, OFFICIAL_PACKAGE_SOURCE_KEYS) || !validOfficialSourceUrl(source.url)) return false;
      } else if (!exactKeys(source, COMMUNITY_PACKAGE_SOURCE_KEYS) ||
          shard.target !== 'xiaomi_ax9000' || shard.flavor !== 'official' ||
          source.url !== KIDDIN9_PACKAGES_URL || source.sha256 !== KIDDIN9_PACKAGES_SHA256 ||
          source.metadata_format !== 'opkg-packages-gzip' || source.metadata_signed !== false ||
          source.candidate_repository !== KIDDIN9_CANDIDATE_REPOSITORY ||
          source.candidate_commit !== KIDDIN9_CANDIDATE_COMMIT ||
          source.catalog_sha256 !== KIDDIN9_CATALOG_SHA256) return false;
      sourceFeeds.add(source.feed);
    }
  }
  return true;
}

function validatePackageCatalogShard(shard, descriptor, catalog) {
  if (!exactKeys(shard, PACKAGE_CATALOG_SHARD_KEYS) || shard.schema_version !== 2 ||
      shard.catalog_version !== catalog.catalog_version || shard.target !== descriptor.target ||
      shard.flavor !== descriptor.flavor || !Array.isArray(shard.packages) ||
      shard.packages.length !== descriptor.package_count || shard.packages.length > MAX_PACKAGE_RECORDS) return false;
  const categories = new Set(catalog.categories.map((category) => category.id));
  const bundleIds = new Set(catalog.components.map((component) => component.id));
  const allowedFeeds = new Set(descriptor.sources.map((source) => source.feed));
  const allowedArchitectures = PACKAGE_ARCHITECTURES[`${descriptor.target}/${descriptor.flavor}`];
  if (!allowedArchitectures) return false;
  const ids = new Set();
  const packageNames = new Set();
  let selectableCount = 0;
  for (const record of shard.packages) {
    if (!exactKeys(record, PACKAGE_RECORD_KEYS) || !validComponentId(record.id) || bundleIds.has(record.id) ||
        !SAFE_OPENWRT_TOKEN.test(record.package) || !validCatalogText(record.version, 160) ||
        !validCatalogText(record.description, 1000, true) || !allowedFeeds.has(record.feed) ||
        !['official', 'kiddin9'].includes(record.source) ||
        ((record.source === 'kiddin9') !== (record.feed === 'kiddin9')) ||
        !Number.isSafeInteger(record.installed_size) || record.installed_size < 0 ||
        !categories.has(record.category) || !SAFE_OPENWRT_TOKEN.test(record.arch) ||
        !allowedArchitectures.has(record.arch) || !PACKAGE_RISKS.has(record.risk) ||
        typeof record.selectable !== 'boolean' || !validCatalogText(record.blocked_reason, 240, true) ||
        (record.selectable && record.blocked_reason !== '') || (!record.selectable && record.blocked_reason === '') ||
        ids.has(record.id) || packageNames.has(`${record.source}/${record.package}`)) return false;
    ids.add(record.id);
    packageNames.add(`${record.source}/${record.package}`);
    if (record.selectable) selectableCount += 1;
  }
  return selectableCount === descriptor.selectable_count;
}

function flavorsForTarget(targetId) {
  return targetId === 'xiaomi_ax9000'
    ? [CUSTOM_BUILD_FLAVORS.official, CUSTOM_BUILD_FLAVORS.nss]
    : [CUSTOM_BUILD_FLAVORS.official];
}

function componentAvailable(component, targetId) {
  return component.supported_targets.includes(targetId);
}

function resolveComponentSelection(catalog, targetId, requestedIds) {
  const packageMap = currentPackageMap;
  const target = catalog.targets.find((item) => item.id === targetId);
  if (!target) return { ok: false, error: '无效的构建目标。' };
  const requested = [...requestedIds];
  if (requested.length > catalog.max_selected_components) {
    return { ok: false, error: `最多可显式选择 ${catalog.max_selected_components} 个组件。` };
  }
  if (new Set(requested).size !== requested.length) return { ok: false, error: '组件选择包含重复项。' };

  const componentsById = new Map(catalog.components.map((item) => [item.id, item]));
  const requestedBundles = requested.filter((id) => componentsById.has(id));
  const requestedPackages = requested.filter((id) => packageMap.has(id));
  if (requestedBundles.length + requestedPackages.length !== requested.length) {
    return { ok: false, error: '选择中包含目录外组件。' };
  }
  const blockedPackage = requestedPackages.map((id) => packageMap.get(id)).find((record) => !record.selectable);
  if (blockedPackage) return { ok: false, error: `官方包不可选择：${blockedPackage.package}（${blockedPackage.blocked_reason}）` };

  const defaults = catalog.components.filter((item) => item.default_for.includes(targetId)).map((item) => item.id).sort();
  const selectedBundles = new Set([...requestedBundles, ...defaults]);
  const queue = [...selectedBundles];
  while (queue.length) {
    const id = queue.shift();
    const component = componentsById.get(id);
    for (const dependency of component.depends) {
      if (!selectedBundles.has(dependency)) {
        selectedBundles.add(dependency);
        queue.push(dependency);
      }
    }
  }
  const unsupported = [...selectedBundles].filter((id) => !componentAvailable(componentsById.get(id), targetId)).sort();
  if (unsupported.length) return { ok: false, error: `组件不支持当前目标：${unsupported.join(', ')}` };

  const resolvedBundles = [...selectedBundles].sort();
  for (const id of resolvedBundles) {
    const component = componentsById.get(id);
    const conflict = component.conflicts.find((other) => selectedBundles.has(other));
    if (conflict) {
      return { ok: false, error: `组件冲突：${component.name} 与 ${componentsById.get(conflict).name} 不能同时选择。` };
    }
  }
  const resolvedPackages = [...requestedPackages].sort();
  const packages = [...new Set([
    ...resolvedBundles.flatMap((id) => componentsById.get(id).packages),
    ...resolvedPackages.map((id) => packageMap.get(id).package)
  ])].sort();
  return {
    ok: true,
    error: '',
    requested_components: [...requested].sort(),
    default_components: defaults,
    resolved_components: [...resolvedBundles, ...resolvedPackages].sort(),
    packages,
    target: {
      id: target.id,
      openwrt_target: target.openwrt_target,
      openwrt_subtarget: target.openwrt_subtarget,
      profile: target.profile
    }
  };
}

function selectedCommunityPackages(resolved) {
  return resolved.requested_components
    .map((id) => currentPackageMap.get(id))
    .filter((record) => record?.source === 'kiddin9')
    .map((record) => record.package)
    .sort();
}

function componentHashPayload(catalog, targetId, flavorId, resolved) {
  return {
    catalog_version: catalog.catalog_version,
    community_packages: selectedCommunityPackages(resolved),
    default_components: [...resolved.default_components],
    flavor: flavorId,
    packages: [...resolved.packages],
    requested_components: [...resolved.requested_components],
    resolved_components: [...resolved.resolved_components],
    schema_version: 2,
    target: targetId
  };
}

function canonicalJson(value) {
  return JSON.stringify(value);
}

async function sha256Hex(value) {
  const bytes = new TextEncoder().encode(value);
  const digest = await globalThis.crypto.subtle.digest('SHA-256', bytes);
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, '0')).join('');
}

function canonicalSortedJson(value) {
  if (Array.isArray(value)) return `[${value.map(canonicalSortedJson).join(',')}]`;
  if (value && typeof value === 'object') {
    return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${canonicalSortedJson(value[key])}`).join(',')}}`;
  }
  return JSON.stringify(value);
}

async function validCommunityCandidateProjection(shard, descriptor) {
  const source = descriptor.sources.find((item) => item.feed === 'kiddin9');
  const records = shard.packages.filter((record) => record.source === 'kiddin9');
  if (!source) return records.length === 0;
  if (source.catalog_sha256 !== KIDDIN9_CATALOG_SHA256 || records.length < 900 || records.length > 1100 ||
      records.some((record) => record.selectable || record.feed !== 'kiddin9')) return false;
  return await sha256Hex(canonicalSortedJson(records)) === source.catalog_sha256;
}

function normalizedBuildRequest(catalog, flavorId, resolved, requestHash) {
  const communityPackages = selectedCommunityPackages(resolved);
  return {
    schema_version: 2,
    catalog_version: catalog.catalog_version,
    target: resolved.target,
    flavor: flavorId,
    requested_components: resolved.requested_components,
    default_components: resolved.default_components,
    resolved_components: resolved.resolved_components,
    packages: resolved.packages,
    community_packages: communityPackages,
    community_feed_required: communityPackages.length > 0,
    request_hash: requestHash
  };
}

function actionsInputs(request) {
  return [
    `target=${request.target.id}`,
    `flavor=${request.flavor}`,
    `components=${request.requested_components.join(',')}`,
    `catalog_version=${request.catalog_version}`,
    `request_hash=${request.request_hash}`
  ].join('\n');
}

function setComponentMessage(message, isError = false) {
  const output = document.querySelector('#component-error');
  output.textContent = message;
  output.hidden = !message;
  output.classList.remove('error');
  if (isError) output.classList.add('error');
}

function setBuildRequestUnavailable(message) {
  componentRequestSequence += 1;
  document.querySelector('#component-packages').textContent = '—';
  document.querySelector('#component-normalized').textContent = '{}';
  document.querySelector('#component-request-hash').textContent = '—';
  document.querySelector('#component-actions-inputs').textContent = '# 等待有效选择 / Waiting for a valid selection';
  document.querySelector('#copy-actions-inputs').disabled = true;
  const workflowLink = document.querySelector('#custom-build-workflow-link');
  workflowLink.hidden = true;
  workflowLink.removeAttribute('href');
  if (message) setComponentMessage(message, true);
}

function populateSelect(select, items, selectedId) {
  const options = items.map((item) => {
    const option = document.createElement('option');
    option.value = item.id;
    option.textContent = item.label || item.display_name || item.title;
    option.selected = item.id === selectedId;
    return option;
  });
  select.replaceChildren(...options);
  select.value = items.some((item) => item.id === selectedId) ? selectedId : (items[0]?.id || '');
}

function selectedTargetAndFlavor() {
  return {
    targetId: document.querySelector('#component-target').value,
    flavorId: document.querySelector('#component-flavor').value
  };
}

function currentResolvedSelection() {
  const { targetId } = selectedTargetAndFlavor();
  return resolveComponentSelection(componentCatalog, targetId, [...requestedComponentIds]);
}

function formatInstalledSize(bytes) {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(bytes < 10240 ? 1 : 0)} KiB`;
  return `${(bytes / (1024 * 1024)).toFixed(bytes < 10 * 1024 * 1024 ? 1 : 0)} MiB`;
}

function makeRiskBadge(risk) {
  const badge = document.createElement('span');
  badge.className = `package-risk package-risk-${risk}`;
  badge.textContent = risk;
  return badge;
}

function makeBundleOption(component) {
  const label = document.createElement('label');
  label.className = 'component-option component-option-bundle';
  const checkbox = document.createElement('input');
  checkbox.type = 'checkbox';
  checkbox.value = component.id;
  checkbox.checked = resolvedComponentIds.has(component.id);
  checkbox.setAttribute('data-component-id', component.id);
  const copy = document.createElement('span');
  copy.className = 'component-option-copy';
  const name = document.createElement('strong');
  name.textContent = component.name;
  const source = document.createElement('span');
  source.className = 'component-source-label';
  source.textContent = '精选套餐 / Curated bundle';
  const detail = document.createElement('small');
  detail.textContent = `${component.description} · ${component.packages.join(', ')}`;
  copy.append(name, source, detail);
  label.append(checkbox, copy);
  checkbox.addEventListener('change', () => changeComponentSelection(component.id, checkbox.checked));
  return label;
}

function makePackageOption(record) {
  const label = document.createElement('label');
  label.className = `component-option package-option${record.selectable ? '' : ' package-option-blocked'}`;
  const checkbox = document.createElement('input');
  checkbox.type = 'checkbox';
  checkbox.value = record.id;
  checkbox.checked = requestedComponentIds.has(record.id);
  checkbox.disabled = !record.selectable;
  checkbox.setAttribute('data-component-id', record.id);
  const copy = document.createElement('span');
  copy.className = 'component-option-copy';
  const titleRow = document.createElement('span');
  titleRow.className = 'package-title-row';
  const name = document.createElement('strong');
  name.textContent = record.package;
  titleRow.append(name, makeRiskBadge(record.risk));
  const meta = document.createElement('span');
  meta.className = 'package-meta';
  meta.textContent = `${record.version} · ${record.arch} · ${record.feed} · ${record.source === 'kiddin9' ? '社区候选 / kiddin9（未审核）' : '官方'} · ${formatInstalledSize(record.installed_size)}`;
  const detail = document.createElement('small');
  detail.textContent = record.description || '暂无说明 / No description';
  copy.append(titleRow, meta, detail);
  if (!record.selectable) {
    const blocked = document.createElement('small');
    blocked.className = 'package-blocked-reason';
    blocked.textContent = `不可选择 / Blocked: ${record.blocked_reason}`;
    copy.append(blocked);
  }
  label.append(checkbox, copy);
  if (record.selectable) {
    checkbox.addEventListener('change', () => changeComponentSelection(record.id, checkbox.checked));
  }
  return label;
}

function renderSelectedOfficialPackages() {
  const container = document.querySelector('#component-selected-official');
  const selected = [...requestedComponentIds]
    .map((id) => currentPackageMap.get(id))
    .filter(Boolean)
    .sort((left, right) => left.package.localeCompare(right.package));
  if (!selected.length) {
    const empty = document.createElement('p');
    empty.className = 'empty-state compact';
    empty.textContent = '尚未选择软件包 / No packages selected.';
    container.replaceChildren(empty);
    return;
  }
  const fragment = document.createDocumentFragment();
  for (const record of selected) {
    const item = document.createElement('div');
    item.className = 'selected-package';
    const copy = document.createElement('span');
    const name = document.createElement('strong');
    name.textContent = record.package;
    const meta = document.createElement('small');
    meta.textContent = `${record.version} · ${record.arch} · ${record.feed} · ${record.source === 'kiddin9' ? '社区候选 / kiddin9（未审核）' : '官方'} · ${formatInstalledSize(record.installed_size)}`;
    copy.append(name, meta);
    const remove = document.createElement('button');
    remove.type = 'button';
    remove.textContent = '移除 / Remove';
    remove.addEventListener('click', () => changeComponentSelection(record.id, false));
    item.append(copy, remove);
    fragment.append(item);
  }
  container.replaceChildren(fragment);
}

function renderComponentChoices() {
  const list = document.querySelector('#component-list');
  if (!componentCatalog) {
    list.replaceChildren();
    return;
  }
  const { targetId } = selectedTargetAndFlavor();
  const query = document.querySelector('#component-search').value.trim().toLocaleLowerCase('zh-CN');
  const categoryFilter = document.querySelector('#component-category').value;
  const sourceFilter = document.querySelector('#component-source').value;
  const riskFilter = document.querySelector('#component-risk').value;
  const feedFilter = document.querySelector('#component-feed').value;
  const fragment = document.createDocumentFragment();
  let bundleCount = 0;

  if (!['official', 'kiddin9'].includes(sourceFilter)) {
    const componentsByCategory = new Map(componentCatalog.categories.map((category) => [category.id, []]));
    for (const component of componentCatalog.components) {
      if (!componentAvailable(component, targetId) || (categoryFilter && categoryFilter !== component.category) ||
          (query && !`${component.name} ${component.description} ${component.id} ${component.packages.join(' ')}`.toLocaleLowerCase('zh-CN').includes(query))) continue;
      componentsByCategory.get(component.category).push(component);
    }
    const categories = [...componentCatalog.categories].sort((left, right) => left.order - right.order);
    for (const category of categories) {
      const components = componentsByCategory.get(category.id);
      if (!components.length) continue;
      const group = document.createElement('section');
      group.className = 'component-category-group';
      const heading = document.createElement('h3');
      heading.textContent = `${category.title} · 精选套餐`;
      const description = document.createElement('p');
      description.className = 'component-category-description';
      description.textContent = category.description;
      group.append(heading, description);
      for (const component of components.sort((left, right) => left.name.localeCompare(right.name))) {
        group.append(makeBundleOption(component));
        bundleCount += 1;
      }
      fragment.append(group);
    }
  }

  const packageMatches = [];
  let packageMatchCount = 0;
  if (query && sourceFilter !== 'bundles' && currentPackageShard) {
    for (const record of currentPackageShard.packages) {
      if ((!categoryFilter || record.category === categoryFilter) &&
          (!riskFilter || record.risk === riskFilter) &&
          (!feedFilter || record.feed === feedFilter) &&
          (sourceFilter === 'all' || sourceFilter === record.source) &&
          currentPackageSearchTerms.get(record.id)?.includes(query)) {
        packageMatchCount += 1;
        if (packageMatches.length < MAX_PACKAGE_RESULTS) packageMatches.push(record);
      }
    }
    if (packageMatchCount) {
      const group = document.createElement('section');
      group.className = 'component-category-group official-package-results';
      const heading = document.createElement('h3');
      heading.textContent = sourceFilter === 'kiddin9' ? '社区候选库 / kiddin9（未审核）' : sourceFilter === 'official' ? 'Official packages · 官方包' : '软件包 / Packages';
      const description = document.createElement('p');
      description.className = 'component-category-description';
      description.textContent = packageMatchCount > MAX_PACKAGE_RESULTS
        ? `命中 ${packageMatchCount} 条，只显示前 ${MAX_PACKAGE_RESULTS} 条。 / ${packageMatchCount} matches; showing first ${MAX_PACKAGE_RESULTS}.`
        : `命中 ${packageMatchCount} 条软件包。 / ${packageMatchCount} package matches.`;
      group.append(heading, description);
      for (const record of packageMatches) group.append(makePackageOption(record));
      fragment.append(group);
    }
  }

  const resultStatus = document.querySelector('#component-result-status');
  if (!query && sourceFilter !== 'bundles') {
    resultStatus.textContent = currentPackageShard
      ? '输入关键词后搜索软件包；为避免浏览器卡顿，不会一次渲染完整目录。 / Search to browse packages.'
      : '官方包目录当前不可用；精选套餐仍可使用。 / Official packages unavailable; curated bundles remain available.';
  } else if (query && sourceFilter !== 'bundles') {
    resultStatus.textContent = currentPackageShard
      ? `软件包命中 ${packageMatchCount} 条${packageMatchCount > MAX_PACKAGE_RESULTS ? `，只显示前 ${MAX_PACKAGE_RESULTS} 条` : ''}。`
      : '官方包目录当前不可用；仅搜索精选套餐。';
  } else {
    resultStatus.textContent = `显示 ${bundleCount} 个精选套餐。 / Showing ${bundleCount} curated bundles.`;
  }

  if (!fragment.children.length) {
    const empty = document.createElement('p');
    empty.className = 'empty-state';
    empty.textContent = !query && ['official', 'kiddin9'].includes(sourceFilter)
      ? '输入关键词搜索软件包；完整目录不会一次性渲染。 / Enter a search term for packages.'
      : '没有匹配当前筛选条件的组件。 / No matching components.';
    fragment.append(empty);
  }
  list.replaceChildren(fragment);
  renderSelectedOfficialPackages();
}

async function updateBuildRequest(preserveMessage = false) {
  const sequence = ++componentRequestSequence;
  const { targetId, flavorId } = selectedTargetAndFlavor();
  const resolved = resolveComponentSelection(componentCatalog, targetId, [...requestedComponentIds]);
  if (!resolved.ok) {
    setBuildRequestUnavailable(resolved.error);
    return;
  }
  resolvedComponentIds = new Set(resolved.resolved_components);
  try {
    const hash = await sha256Hex(canonicalJson(componentHashPayload(componentCatalog, targetId, flavorId, resolved)));
    if (sequence !== componentRequestSequence) return;
    const request = normalizedBuildRequest(componentCatalog, flavorId, resolved, hash);
    document.querySelector('#component-packages').textContent = request.packages.join('\n');
    document.querySelector('#component-normalized').textContent = JSON.stringify(request, null, 2);
    document.querySelector('#component-request-hash').textContent = `sha256:${hash}`;
    document.querySelector('#component-actions-inputs').textContent = actionsInputs(request);
    document.querySelector('#copy-actions-inputs').disabled = false;
    const workflowLink = document.querySelector('#custom-build-workflow-link');
    workflowLink.href = CUSTOM_BUILD_WORKFLOW_URL;
    workflowLink.hidden = false;
    if (!preserveMessage) setComponentMessage('');
  } catch (error) {
    if (sequence !== componentRequestSequence) return;
    setBuildRequestUnavailable('浏览器无法计算请求哈希，已禁用构建入口。');
    console.error('Unable to hash normalized component request:', error);
  }
}

function changeComponentSelection(componentId, enabled) {
  const previous = new Set(requestedComponentIds);
  let preserveMessage = false;
  if (enabled) requestedComponentIds.add(componentId);
  else requestedComponentIds.delete(componentId);
  const resolved = currentResolvedSelection();
  if (!resolved.ok) {
    requestedComponentIds = previous;
    preserveMessage = true;
    setComponentMessage(resolved.error, true);
  } else {
    resolvedComponentIds = new Set(resolved.resolved_components);
    if (!enabled && resolvedComponentIds.has(componentId)) {
      preserveMessage = true;
      setComponentMessage(`组件 ${componentId} 是默认组件或仍被其他组件依赖，不能移除。`, true);
    } else {
      setComponentMessage('');
    }
  }
  renderComponentChoices();
  return updateBuildRequest(preserveMessage);
}

function clearOfficialPackageSelections() {
  for (const id of currentPackageMap.keys()) requestedComponentIds.delete(id);
  currentPackageShard = null;
  currentPackageMap = new Map();
  currentPackageSearchTerms = new Map();
  populateSelect(document.querySelector('#component-feed'), [{ id: '', title: '全部来源 / All feeds' }], '');
  document.querySelector('#component-feed').disabled = true;
  document.querySelector('#component-risk').disabled = true;
}

function packageShardDescriptor(targetId, flavorId) {
  return packageCatalogRoot?.shards.find((shard) => shard.target === targetId && shard.flavor === flavorId) || null;
}

function setPackageCatalogStatus(message, isError = false) {
  const status = document.querySelector('#component-package-status');
  status.textContent = message;
  status.classList.remove('error');
  if (isError) status.classList.add('error');
}

function packageShardCacheKey(descriptor) {
  return `${descriptor.target}/${descriptor.flavor}/${descriptor.sha256}`;
}

function activateVerifiedPackageShard(shard, searchTerms) {
  currentPackageShard = shard;
  currentPackageMap = new Map(shard.packages.map((record) => [record.id, record]));
  currentPackageSearchTerms = searchTerms;
}

function packageSearchTerms(shard) {
  return new Map(shard.packages.map((record) => [
    record.id,
    `${record.package} ${record.description} ${record.version} ${record.arch} ${record.feed} ${record.source} ${record.category} ${record.id}`
      .toLocaleLowerCase('zh-CN')
  ]));
}

async function loadPackageShardForSelection() {
  const sequence = ++packageShardRequestSequence;
  clearOfficialPackageSelections();
  renderComponentChoices();
  await updateBuildRequest();
  const { targetId, flavorId } = selectedTargetAndFlavor();
  if (!packageCatalogRoot) {
    setPackageCatalogStatus('官方包索引不可用；精选套餐仍可使用。 / Official package index unavailable.', true);
    return;
  }
  const descriptor = packageShardDescriptor(targetId, flavorId);
  if (!descriptor) {
    setPackageCatalogStatus(`OpenWrt ${packageCatalogRoot.openwrt_version} · 当前目标暂无官方包分片；精选套餐仍可使用。`, true);
    return;
  }
  setPackageCatalogStatus(`OpenWrt ${packageCatalogRoot.openwrt_version} · 正在校验 ${targetId}/${flavorId} 官方包…`);
  try {
    const cacheKey = packageShardCacheKey(descriptor);
    let verified = verifiedPackageShardCache.get(cacheKey);
    if (!verified) {
      const response = await fetch(packageShardFetchUrl(descriptor.path), { cache: 'no-store', credentials: 'same-origin' });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const raw = await response.text();
      const digest = await sha256Hex(raw);
      if (digest !== descriptor.sha256) throw new Error('package shard sha256 mismatch');
      const shard = JSON.parse(raw);
      if (!validatePackageCatalogShard(shard, descriptor, componentCatalog)) {
        throw new Error('unexpected package shard schema');
      }
      if (!await validCommunityCandidateProjection(shard, descriptor)) {
        throw new Error('community candidate projection mismatch');
      }
      verified = { shard, searchTerms: packageSearchTerms(shard) };
      verifiedPackageShardCache.set(cacheKey, verified);
    }
    const selected = selectedTargetAndFlavor();
    if (sequence !== packageShardRequestSequence || selected.targetId !== targetId || selected.flavorId !== flavorId) return;
    activateVerifiedPackageShard(verified.shard, verified.searchTerms);
    const feeds = [...new Set(verified.shard.packages.map((record) => record.feed))].sort();
    populateSelect(document.querySelector('#component-feed'), [
      { id: '', title: '全部来源 / All feeds' },
      ...feeds.map((feed) => ({ id: feed, title: feed }))
    ], '');
    document.querySelector('#component-feed').disabled = false;
    document.querySelector('#component-risk').disabled = false;
    const communityCount = verified.shard.packages.filter((record) => record.source === 'kiddin9').length;
    setPackageCatalogStatus(
      `OpenWrt ${packageCatalogRoot.openwrt_version} · ${descriptor.package_count} 个包，${descriptor.selectable_count} 个可选择` +
      (communityCount ? ` · 社区候选 ${communityCount}（未审核、全部不可选；仅记录锁定 Git provenance）` : '')
    );
    renderComponentChoices();
    await updateBuildRequest();
  } catch (error) {
    if (sequence !== packageShardRequestSequence) return;
    clearOfficialPackageSelections();
    setPackageCatalogStatus(
      `OpenWrt ${packageCatalogRoot.openwrt_version} · 官方包校验失败；精选套餐仍可使用。 / Official packages disabled.`, true
    );
    renderComponentChoices();
    await updateBuildRequest();
    console.error('Unable to load the verified official package shard:', error);
  }
}

function resetComponentsForTarget() {
  const { targetId } = selectedTargetAndFlavor();
  const compatible = new Set(componentCatalog.components
    .filter((component) => componentAvailable(component, targetId))
    .map((component) => component.id));
  requestedComponentIds = new Set([...requestedComponentIds].filter((id) => compatible.has(id)));
  const resolved = currentResolvedSelection();
  if (!resolved.ok) {
    requestedComponentIds.clear();
    setBuildRequestUnavailable(resolved.error);
    resolvedComponentIds.clear();
  } else {
    resolvedComponentIds = new Set(resolved.resolved_components);
    setComponentMessage('');
  }
  renderComponentChoices();
  return updateBuildRequest();
}

function setupComponentBuilder(catalog) {
  componentCatalog = catalog;
  packageCatalogRoot = null;
  currentPackageShard = null;
  currentPackageMap = new Map();
  currentPackageSearchTerms = new Map();
  requestedComponentIds.clear();
  resolvedComponentIds.clear();
  const targetSelect = document.querySelector('#component-target');
  const flavorSelect = document.querySelector('#component-flavor');
  const categorySelect = document.querySelector('#component-category');
  const sourceSelect = document.querySelector('#component-source');
  const riskSelect = document.querySelector('#component-risk');
  const feedSelect = document.querySelector('#component-feed');
  targetSelect.disabled = false;
  flavorSelect.disabled = false;
  categorySelect.disabled = false;
  sourceSelect.disabled = false;
  populateSelect(targetSelect, catalog.targets, catalog.targets[0].id);
  populateSelect(categorySelect, [{ id: '', title: '全部分类 / All categories' }, ...catalog.categories], '');
  populateSelect(sourceSelect, [
    { id: 'all', title: '全部来源 / All sources' },
    { id: 'bundles', title: '精选套餐 / Curated bundles' },
    { id: 'official', title: 'Official packages / 官方包' },
    { id: 'kiddin9', title: '社区候选库 / kiddin9（未审核）' }
  ], 'all');
  populateSelect(riskSelect, [
    { id: '', title: '全部风险 / All risks' },
    { id: 'standard', title: 'standard · 标准' },
    { id: 'advanced', title: 'advanced · 高级' },
    { id: 'system', title: 'system · 系统级' }
  ], '');
  populateSelect(feedSelect, [{ id: '', title: '全部来源 / All feeds' }], '');
  document.querySelector('#component-search').value = '';
  riskSelect.disabled = true;
  feedSelect.disabled = true;

  async function updateFlavors() {
    packageShardRequestSequence += 1;
    const available = flavorsForTarget(targetSelect.value);
    populateSelect(flavorSelect, available, available[0].id);
    await resetComponentsForTarget();
    return loadPackageShardForSelection();
  }
  async function updateFlavorSelection() {
    packageShardRequestSequence += 1;
    await resetComponentsForTarget();
    return loadPackageShardForSelection();
  }
  targetSelect.addEventListener('change', updateFlavors);
  flavorSelect.addEventListener('change', updateFlavorSelection);
  for (const select of [categorySelect, sourceSelect, riskSelect, feedSelect]) {
    select.addEventListener('change', renderComponentChoices);
  }
  document.querySelector('#component-search').addEventListener('input', () => {
    if (componentSearchTimer !== null) clearTimeout(componentSearchTimer);
    componentSearchTimer = setTimeout(() => {
      componentSearchTimer = null;
      renderComponentChoices();
    }, 120);
  });
  return updateFlavors();
}

async function loadPackageCatalogRoot(catalog) {
  try {
    const response = await fetch(PACKAGE_CATALOG_URL, { cache: 'no-store', credentials: 'same-origin' });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const root = await response.json();
    if (!validatePackageCatalogRoot(root, catalog)) throw new Error('unexpected package catalog root schema');
    packageCatalogRoot = root;
    setPackageCatalogStatus(`OpenWrt ${root.openwrt_version} · 官方包根索引已验证 / Package index verified`);
    return loadPackageShardForSelection();
  } catch (error) {
    packageCatalogRoot = null;
    clearOfficialPackageSelections();
    setPackageCatalogStatus('官方包索引不可用；精选套餐仍可使用。 / Official packages disabled.', true);
    renderComponentChoices();
    await updateBuildRequest();
    console.error('Unable to load the official package catalog root:', error);
  }
}

async function loadComponentCatalog() {
  const status = document.querySelector('#component-status');
  try {
    const response = await fetch(COMPONENT_CATALOG_URL, { cache: 'no-store', credentials: 'same-origin' });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const catalog = await response.json();
    if (!validateComponentCatalog(catalog)) throw new Error('unexpected component catalog schema');
    await setupComponentBuilder(catalog);
    status.classList.remove('error');
    status.textContent = `精选套餐目录 ${catalog.catalog_version} 已验证 / Curated bundles verified`;
    await loadPackageCatalogRoot(catalog);
  } catch (error) {
    componentCatalog = null;
    packageCatalogRoot = null;
    currentPackageShard = null;
    currentPackageMap = new Map();
    requestedComponentIds.clear();
    resolvedComponentIds.clear();
    status.classList.add('error');
    status.textContent = '精选套餐目录暂不可用；已禁用自定义构建入口。 / Catalog unavailable; custom builds disabled.';
    setPackageCatalogStatus('等待有效精选套餐目录。 / Waiting for curated catalog.', true);
    document.querySelector('#component-list').replaceChildren();
    document.querySelector('#component-selected-official').replaceChildren();
    setBuildRequestUnavailable('无法验证精选套餐目录。');
    console.error('Unable to load the allowlisted component catalog:', error);
  }
}

async function copyActionsInputs() {
  const button = document.querySelector('#copy-actions-inputs');
  try {
    await navigator.clipboard.writeText(document.querySelector('#component-actions-inputs').textContent);
    button.textContent = '已复制 / Copied';
    window.setTimeout(() => { button.textContent = '复制 Inputs / Copy inputs'; }, 1800);
  } catch {
    button.textContent = '请手动复制 / Select manually';
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
document.querySelector('#copy-actions-inputs').addEventListener('click', copyActionsInputs);
loadReleases();
loadComponentCatalog();
