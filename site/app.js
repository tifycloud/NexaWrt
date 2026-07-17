'use strict';

const REPOSITORY = 'tifycloud/NexaWrt';
const FLAVORS = ['official', 'nss'];
const PROVENANCE_LABELS = {
  provenance_archive: 'Archive bundle',
  provenance_checksums: 'Checksums bundle',
  provenance_firmware: 'Firmware bundle',
  provenance_sbom: 'SBOM bundle'
};

function makeLink(label, url, className = '') {
  const link = document.createElement('a');
  link.textContent = label;
  link.href = url;
  link.target = '_blank';
  link.rel = 'noopener noreferrer';
  if (className) link.className = className;
  return link;
}

function isSafeGitHubUrl(value) {
  try {
    const url = new URL(value);
    return url.protocol === 'https:' && url.hostname === 'github.com' &&
      url.pathname.startsWith(`/${REPOSITORY}/releases/`);
  } catch {
    return false;
  }
}

function validRelease(release, flavor) {
  if (!release || typeof release !== 'object') return false;
  const versionPattern = /^v(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)-rc\.(?:0|[1-9]\d*)$/;
  const tagPattern = flavor === 'nss'
    ? /^ram-test-nss-v(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)-rc\.(?:0|[1-9]\d*)$/
    : /^ram-test-v(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)-rc\.(?:0|[1-9]\d*)$/;
  const expectedTag = flavor === 'nss' ? `ram-test-nss-${release.version}` : `ram-test-${release.version}`;
  if (!tagPattern.test(release.tag) || typeof release.version !== 'string' ||
      !versionPattern.test(release.version) || release.tag !== expectedTag || !isSafeGitHubUrl(release.url)) return false;
  if (!release.assets || typeof release.assets !== 'object') return false;
  const archive = `NexaWrt-AX9000-${flavor}-${release.version}-verified-dist.tar.gz`;
  const expectedNames = {
    archive,
    checksum: `${archive}.sha256`,
    provenance_archive: 'archive.provenance.bundle.json',
    provenance_checksums: 'checksums.provenance.bundle.json',
    provenance_firmware: 'firmware.provenance.bundle.json',
    provenance_sbom: 'sbom.provenance.bundle.json'
  };
  return Object.entries(expectedNames).every(([key, expectedName]) => {
    const asset = release.assets[key];
    return asset && asset.name === expectedName && isSafeGitHubUrl(asset.url) &&
      new URL(asset.url).pathname.endsWith(`/${expectedName}`);
  });
}

function formatDate(timestamp) {
  const date = new Date(timestamp);
  if (Number.isNaN(date.getTime())) return '—';
  return new Intl.DateTimeFormat(['zh-CN', 'en'], {
    year: 'numeric', month: 'short', day: '2-digit', timeZone: 'UTC'
  }).format(date);
}

function showUnavailable(card) {
  const downloads = card.querySelector('[data-field="downloads"]');
  const message = document.createElement('span');
  message.className = 'unavailable';
  message.textContent = '暂无完整已验证资产 / No complete verified release yet';
  downloads.replaceChildren(message);
  card.querySelector('details').hidden = true;
}

function renderCard(flavor, release) {
  const card = document.querySelector(`[data-flavor="${flavor}"]`);
  if (!card) return;
  if (!validRelease(release, flavor)) {
    showUnavailable(card);
    return;
  }

  card.querySelector('[data-field="version"]').textContent = release.version;
  const date = card.querySelector('[data-field="date"]');
  date.textContent = formatDate(release.published_at);
  date.dateTime = release.published_at;

  const downloads = card.querySelector('[data-field="downloads"]');
  downloads.replaceChildren(
    makeLink('下载已验证归档 ↓', release.assets.archive.url),
    makeLink('SHA-256', release.assets.checksum.url)
  );

  const provenance = card.querySelector('[data-field="provenance"]');
  provenance.replaceChildren(...Object.entries(PROVENANCE_LABELS).map(([key, label]) =>
    makeLink(label, release.assets[key].url)
  ));

  const releaseUrl = card.querySelector('[data-field="release-url"]');
  releaseUrl.href = release.url;
  releaseUrl.hidden = false;
}

function renderHistory(flavorData) {
  const history = document.querySelector('#release-history');
  const rows = [];
  for (const flavor of FLAVORS) {
    const releases = Array.isArray(flavorData[flavor]?.history) ? flavorData[flavor].history : [];
    for (const release of releases) {
      if (validRelease(release, flavor)) rows.push({ flavor, release });
    }
  }
  rows.sort((left, right) => right.release.published_at.localeCompare(left.release.published_at));

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
    flavorLabel.textContent = flavor === 'nss' ? 'NSS · EXP' : 'OFFICIAL';

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

async function loadReleases() {
  const status = document.querySelector('#data-status');
  try {
    const response = await fetch('releases.json', { cache: 'no-store', credentials: 'same-origin' });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const data = await response.json();
    if (data.schema_version !== 1 || data.repository !== REPOSITORY || !data.flavors) {
      throw new Error('unexpected release index schema');
    }
    for (const flavor of FLAVORS) renderCard(flavor, data.flavors[flavor]?.latest);
    renderHistory(data.flavors);
    status.textContent = data.generated_at === '1970-01-01T00:00:00Z'
      ? '尚未发布版本 / No release index has been published yet'
      : `索引更新 / Index generated: ${formatDate(data.generated_at)} UTC`;
  } catch (error) {
    for (const flavor of FLAVORS) renderCard(flavor, null);
    renderHistory({});
    status.classList.add('error');
    status.textContent = '发布索引暂不可用；请勿猜测下载地址。 / Release index unavailable; never guess asset URLs.';
    console.error('Unable to load the allowlisted release index:', error);
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

function generateSnippet(event) {
  event.preventDefault();
  const form = event.currentTarget;
  const error = document.querySelector('#config-error');
  const hostname = form.elements.hostname.value.trim().toLowerCase();
  const lanIp = form.elements['lan-ip'].value.trim();
  const zonename = form.elements.timezone.value;
  const country = form.elements.country.value;
  const hostnamePattern = /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/;

  let problem = '';
  if (!hostnamePattern.test(hostname)) problem = '主机名必须为 1–63 个字母、数字或中划线，且不能以中划线开头或结尾。';
  else if (!isPrivateIPv4(lanIp)) problem = 'LAN IP 必须是有效的 RFC1918 私有 IPv4 主机地址。';
  else if (!Object.hasOwn(TIMEZONES, zonename)) problem = '请选择列表中的时区。';
  else if (!COUNTRIES.has(country)) problem = '请选择列表中的无线国家码。';

  if (problem) {
    error.textContent = problem;
    error.hidden = false;
    document.querySelector('#copy-snippet').disabled = true;
    return;
  }
  error.hidden = true;

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
  document.querySelector('#config-output').textContent = snippet;
  document.querySelector('#copy-snippet').disabled = false;
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

document.querySelector('#config-form').addEventListener('submit', generateSnippet);
document.querySelector('#copy-snippet').addEventListener('click', copySnippet);
loadReleases();
