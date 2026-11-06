import {connected, makeMain, place, snap} from './geometry.js';

const $ = id => document.getElementById(id);
const svg = $('diagram');
let current = [];
let draft = [];
let selected = null;
let modes = [];
let token = '';
let preview = null;
let canUndo = false;
let busy = false;
let online = false;
let drag = null;
let projection = null;
let stateRequest = 0;
let modeRequest = 0;

const selectedDisplay = () => current.find(d => d.uuid === selected);
const displayName = d => d?.name || (d ? `Display ${d.id}` : 'Display');
const sortIDs = (a, b) => a.uuid < b.uuid ? -1 : a.uuid > b.uuid ? 1 : 0;
const geometry = screens => [...screens].sort(sortIDs).map(({uuid, x, y, width, height}) => ({uuid, x, y, width, height}));
const fingerprint = screens => JSON.stringify(geometry(screens));
const edited = () => fingerprint(draft) !== fingerprint(current);
const canArrange = () => current.length > 1 && !current.some(d => d.mirrored);
const positionOf = d => ({uuid: d.uuid, x: d.x, y: d.y});
const dims = (w, h) => `${w} × ${h}`;
const hz = rate => rate ? `${Number(rate.toFixed(2))} Hz` : 'Auto';
const pct = scale => Number.isFinite(scale) ? `${Math.round(scale)}%` : '—';
const modeKey = mode => `${mode.width}x${mode.height}:${mode.hidpi}`;

async function request(path, body) {
  const options = {cache: 'no-store', signal: AbortSignal.timeout(16000)};
  if (body !== undefined) {
    Object.assign(options, {method: 'POST', body: JSON.stringify(body),
      headers: {'Content-Type': 'application/json', 'X-Monitor-Token': token}});
  }
  const response = await fetch(path, options);
  const data = await response.json();
  if (!response.ok) throw new Error(data.error || 'The dashboard request failed.');
  return data;
}

function notice(text, error = false) {
  $('notice').textContent = text;
  $('notice').classList.toggle('error', error);
  $('notice').hidden = !text;
}

function connection(isOnline) {
  online = isOnline;
  $('connection').textContent = isOnline ? 'Service online' : 'Service offline';
  $('connection').parentElement.classList.toggle('online', isOnline);
}

function option(select, label, value) {
  select.append(new Option(label, value));
}

async function reload() {
  const sequence = ++stateRequest;
  try {
    const response = await request('/api/state');
    if (sequence !== stateRequest) return;
    connection(true);
    token = response.token;
    const next = response.displays;
    const changed = fingerprint(next) !== fingerprint(current);
    const lostDraft = changed && edited();
    const oldMode = JSON.stringify(selectedDisplay()?.current);
    const oldSelection = selected;
    current = next;
    if (changed) {
      drag = null;
      svg.classList.remove('dragging');
      draft = current.map(d => ({...d}));
      if (lostDraft) notice('The connected desktop changed. The map has been reloaded.');
    }
    if (!selectedDisplay()) selected = current.find(d => d.main)?.uuid || current[0]?.uuid || null;
    preview = response.preview;
    canUndo = response.can_undo_layout;
    const modeChanged = oldSelection !== selected || oldMode !== JSON.stringify(selectedDisplay()?.current);
    $('count').textContent = `${current.length} connected`;
    if (changed || oldSelection !== selected) renderMap();
    $('map-empty').hidden = current.length > 0;
    $('map-empty').querySelector('strong').textContent = 'No active displays';
    $('map-empty').querySelector('span').textContent = 'Connect or wake a monitor, then refresh.';
    if (changed || modeChanged) {
      renderInspector();
      if (modeChanged) $('mode').replaceChildren();
      await loadModes();
    }
    renderControls();
    renderPreview();
  } catch (error) {
    if (sequence !== stateRequest) return;
    connection(false);
    notice(error.message, true);
    renderControls();
  }
}

async function loadModes() {
  const sequence = ++modeRequest;
  modes = [];
  renderModes();
  if (!selectedDisplay()?.current) return;
  try {
    const data = await request(`/api/modes?display=${encodeURIComponent(selected)}`);
    if (sequence !== modeRequest) return;
    modes = data.modes;
    renderModes();
  } catch (error) {
    if (sequence === modeRequest) notice(error.message, true);
  }
}

function choose(uuid) {
  if (selected === uuid) return;
  selected = uuid;
  $('mode').replaceChildren();
  renderMap();
  renderInspector();
  renderControls();
  loadModes();
}

function renderInspector() {
  const active = selectedDisplay();
  $('display-list').replaceChildren();
  current.forEach((display, index) => {
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'display-item';
    button.setAttribute('aria-pressed', display.uuid === selected);
    const number = document.createElement('span');
    number.className = 'number';
    number.textContent = index + 1;
    const name = document.createElement('strong');
    name.textContent = displayName(display);
    const kind = document.createElement('span');
    kind.textContent = display.main ? 'MAIN' : display.built_in ? 'BUILT-IN' : 'EXTERNAL';
    button.append(number, name, kind);
    button.addEventListener('click', () => choose(display.uuid));
    $('display-list').append(button);
  });
  $('inspector-empty').hidden = Boolean(active?.current);
  $('settings').hidden = !active?.current;
  if (!active?.current) return;
  $('size-value').textContent = dims(active.current.width, active.current.height);
  $('hz-value').textContent = hz(active.current.hz);
  $('scale-value').textContent = pct(active.scale_percent);
}

function renderModes() {
  const select = $('mode');
  const old = select.value;
  const active = selectedDisplay()?.current;
  select.replaceChildren();
  const groups = new Map();
  for (const mode of modes) {
    if (!mode.hidpi && !$('show-standard').checked) continue;
    groups.set(modeKey(mode), mode);
  }
  if (active && !groups.has(modeKey(active))) {
    groups.set(modeKey(active), {...active, scale_percent: selectedDisplay().scale_percent});
  }
  const choices = [...groups.values()].sort((a, b) => a.scale_percent - b.scale_percent || Number(b.hidpi) - Number(a.hidpi));
  for (const mode of choices) {
    const detail = mode.hidpi ? `${pct(mode.scale_percent)} HiDPI` : 'Standard';
    option(select, `${dims(mode.width, mode.height)} · ${detail}`, modeKey(mode));
  }
  if (!choices.length) option(select, 'Loading modes…', '');
  else if (groups.has(old)) select.value = old;
  else if (active && groups.has(modeKey(active))) select.value = modeKey(active);
  renderRates();
}

function renderRates() {
  const select = $('refresh');
  const active = selectedDisplay()?.current;
  const old = select.value;
  const rates = [...new Set(modes.filter(m => modeKey(m) === $('mode').value).map(m => m.hz))].sort((a, b) => b - a);
  select.replaceChildren();
  rates.forEach(rate => option(select, hz(rate), rate));
  if (!rates.length) option(select, '—', '');
  else if (old && rates.includes(Number(old))) select.value = old;
  else if (rates.includes(active?.hz)) select.value = active.hz;
  renderControls();
}

function createSvg(type, attributes = {}, text = '') {
  const item = document.createElementNS('http://www.w3.org/2000/svg', type);
  Object.entries(attributes).forEach(([key, value]) => item.setAttribute(key, value));
  if (text) item.textContent = text;
  return item;
}

function renderMap(frozen = false) {
  svg.replaceChildren();
  $('map-empty').hidden = draft.length > 0;
  if (!draft.length) return;
  if (!frozen || !projection) {
    const minX = Math.min(...draft.map(d => d.x));
    const minY = Math.min(...draft.map(d => d.y));
    const width = Math.max(...draft.map(d => d.x + d.width)) - minX;
    const height = Math.max(...draft.map(d => d.y + d.height)) - minY;
    const scale = Math.min(615 / width, 236 / height);
    projection = {scale, x: (760 - width * scale) / 2 - minX * scale,
      y: (325 - height * scale) / 2 - minY * scale};
  }
  const defs = createSvg('defs');
  [['screen-idle', '#514e82', '#2b2d51'], ['screen-active', '#786bed', '#3e408d']].forEach(([id, light, dark]) => {
    const gradient = createSvg('linearGradient', {id, x1: '0%', y1: '0%', x2: '100%', y2: '100%'});
    gradient.append(createSvg('stop', {offset: 0, 'stop-color': light}), createSvg('stop', {offset: 1, 'stop-color': dark}));
    defs.append(gradient);
  });
  svg.append(defs);
  draft.forEach((display, index) => {
    const {scale, x: left, y: top} = projection;
    const x = left + display.x * scale, y = top + display.y * scale;
    const w = display.width * scale, h = display.height * scale;
    const inner = Math.max(2, Math.min(7, w * .04, h * .06));
    const group = createSvg('g', {
      class: `monitor-node ${display.uuid === selected ? 'selected' : ''} ${canArrange() && !display.main ? 'movable' : ''}`,
      'data-uuid': display.uuid, transform: `translate(${x} ${y})`, tabindex: 0, role: 'button',
      'aria-label': `${displayName(display)}${display.main ? ', main display' : ''}`,
      'aria-pressed': display.uuid === selected,
    });
    group.append(createSvg('rect', {class: 'monitor-frame', width: w, height: h, rx: Math.min(9, w / 5, h / 5)}),
      createSvg('rect', {class: 'monitor-screen', x: inner, y: inner,
        width: Math.max(0, w - 2 * inner), height: Math.max(0, h - 2 * inner), rx: inner / 2}));
    if (display.main) group.append(createSvg('rect', {class: 'main-marker', x: w * .37, y: inner, width: w * .26, height: 3, rx: 2}));
    if (w > 45 && h > 35) {
      group.append(createSvg('text', {class: 'monitor-index', x: inner + 9, y: inner + 15, 'font-size': 12}, String(index + 1)));
    }
    if (w > 86 && h > 60) {
      const name = displayName(display);
      const size = Math.max(9, Math.min(20, (w - 18) / Math.max(6, name.length * .64), h / 5));
      group.append(createSvg('text', {class: 'monitor-name', x: w / 2, y: h / 2, 'font-size': size}, name),
        createSvg('text', {class: 'monitor-detail', x: w / 2, y: h / 2 + size + 4,
          'font-size': Math.min(13, size * .76)}, dims(display.width, display.height)));
    }
    svg.append(group);
  });
}

function renderControls() {
  const hasDraft = edited();
  const arranging = canArrange();
  const active = draft.find(d => d.uuid === selected);
  const blocked = busy || !online || Boolean(preview);
  $('layout-status').textContent = hasDraft ? 'UNSAVED LAYOUT' : 'DESKTOP MAP';
  $('layout-status').classList.toggle('edited', hasDraft);
  $('map-hint').textContent = !arranging
    ? (current.some(d => d.mirrored) ? 'Turn off mirroring in System Settings to arrange displays.' : 'Connect another display to arrange your desktop.')
    : hasDraft ? 'Apply your layout to save the new positions.' : 'Drag a secondary display or use the arrow controls.';
  $('apply-layout').disabled = blocked || !arranging || !hasDraft || !connected(draft);
  $('undo-layout').disabled = blocked || hasDraft || !canUndo;
  $('reset-layout').hidden = !hasDraft;
  $('reset-layout').disabled = busy;
  $('placement').hidden = !arranging || !active || active.main;
  const anchor = $('anchor'), oldAnchor = anchor.value;
  anchor.replaceChildren();
  draft.filter(d => d.uuid !== selected).forEach(d => option(anchor, displayName(d), d.uuid));
  if ([...anchor.options].some(o => o.value === oldAnchor)) anchor.value = oldAnchor;
  else if (draft.some(d => d.main)) anchor.value = draft.find(d => d.main).uuid;
  for (const button of document.querySelectorAll('[data-side]')) button.disabled = blocked;
  $('make-main').disabled = blocked;
  $('apply-mode').disabled = blocked || hasDraft || !modes.length || !selectedDisplay()?.current || $('refresh').value === '';
  $('apply-mode').textContent = $('preview-mode').checked ? 'Preview mode' : 'Apply mode';
  $('undo-mode').disabled = blocked || hasDraft;
  $('keep').disabled = busy || !online;
  $('revert').disabled = busy || !online;
  $('reload').disabled = busy;
}

function renderPreview() {
  $('preview-bar').hidden = !preview;
  if (preview) {
    const seconds = Math.max(0, Math.ceil(preview.expires_at - Date.now() / 1000));
    $('countdown').textContent = seconds ? `Restores automatically in ${seconds}s` : 'Restoring the previous mode…';
  }
}

async function action(path, body, message) {
  if (busy) return;
  busy = true;
  renderControls();
  notice('');
  try {
    const result = await request(path, body);
    if (result.layout) {
      draft = current.map(d => ({...d}));
    }
    await reload();
    notice(result.adjusted ? 'macOS adjusted the positions to fit. The map shows the saved layout.' : message);
  } catch (error) {
    notice(error.message, true);
  } finally {
    busy = false;
    renderControls();
  }
}

function pointer(event) {
  return new DOMPoint(event.clientX, event.clientY).matrixTransform(svg.getScreenCTM().inverse());
}

svg.addEventListener('pointerdown', event => {
  const uuid = event.target.closest('[data-uuid]')?.dataset.uuid;
  if (!uuid || event.button !== 0) return;
  choose(uuid);
  const screen = draft.find(d => d.uuid === uuid);
  if (!canArrange() || screen.main || busy || preview || !online) return;
  const point = pointer(event);
  drag = {uuid, id: event.pointerId, x: point.x, y: point.y,
    origin: positionOf(screen), original: draft.map(d => ({...d})), moved: false};
  svg.setPointerCapture(event.pointerId);
});
svg.addEventListener('pointermove', event => {
  if (!drag || event.pointerId !== drag.id) return;
  const point = pointer(event);
  const dx = point.x - drag.x, dy = point.y - drag.y;
  if (!drag.moved && Math.hypot(dx, dy) < 4) return;
  drag.moved = true;
  const screen = draft.find(d => d.uuid === drag.uuid);
  screen.x = Math.round(drag.origin.x + dx / projection.scale);
  screen.y = Math.round(drag.origin.y + dy / projection.scale);
  svg.classList.add('dragging');
  renderMap(true);
});
function finishDrag(event) {
  if (!drag || event.pointerId !== drag.id) return;
  const {uuid, original, moved} = drag;
  drag = null;
  svg.classList.remove('dragging');
  if (moved) {
    const screen = draft.find(d => d.uuid === uuid);
    const target = event.type === 'pointerup' ? snap(draft, uuid, screen) : null;
    draft = target ? draft.map(d => d.uuid === uuid ? {...d, ...target} : d) : original;
  }
  renderMap();
  renderControls();
}
svg.addEventListener('pointerup', finishDrag);
svg.addEventListener('pointercancel', finishDrag);
svg.addEventListener('lostpointercapture', finishDrag);
svg.addEventListener('keydown', event => {
  const uuid = event.target.closest('[data-uuid]')?.dataset.uuid;
  if (uuid && (event.key === 'Enter' || event.key === ' ')) {
    event.preventDefault();
    choose(uuid);
    [...svg.querySelectorAll('[data-uuid]')].find(node => node.dataset.uuid === uuid)?.focus();
  }
});
for (const button of document.querySelectorAll('[data-side]')) {
  button.addEventListener('click', () => {
    const screen = draft.find(d => d.uuid === selected);
    const anchor = draft.find(d => d.uuid === $('anchor').value);
    const point = place(screen, anchor, button.dataset.side);
    const target = snap(draft, selected, point);
    if (!target) return notice('That placement would separate the desktop.', true);
    draft = draft.map(d => d.uuid === selected ? {...d, ...target} : d);
    renderMap();
    renderControls();
  });
}
$('make-main').addEventListener('click', () => { draft = makeMain(draft, selected); renderMap(); renderControls(); });
$('reset-layout').addEventListener('click', () => {
  draft = current.map(d => ({...d}));
  renderMap();
  renderControls();
});
$('apply-layout').addEventListener('click', () => action('/api/layout',
  {positions: draft.map(positionOf), expected: geometry(current)}, 'Display layout saved.'));
$('undo-layout').addEventListener('click', () => action('/api/layout/undo', {}, 'Previous layout restored.'));
$('reload').addEventListener('click', reload);
$('show-standard').addEventListener('change', renderModes);
$('mode').addEventListener('change', renderRates);
$('preview-mode').addEventListener('change', renderControls);
$('settings').addEventListener('submit', event => {
  event.preventDefault();
  const rate = Number($('refresh').value);
  const mode = modes.find(m => modeKey(m) === $('mode').value && m.hz === rate);
  if (!mode) return;
  action('/api/mode', {display: selected, width: mode.width, height: mode.height, hz: mode.hz,
    hidpi: mode.hidpi, preview: $('preview-mode').checked, permanent: $('remember').checked},
  $('preview-mode').checked ? 'Mode preview is active.' : 'Display mode applied.');
});
$('undo-mode').addEventListener('click', () => action('/api/mode/undo', {}, 'Previous display mode restored.'));
$('keep').addEventListener('click', () => action('/api/confirm', {token: preview.token}, 'Display mode kept.'));
$('revert').addEventListener('click', () => action('/api/revert', {token: preview.token}, 'Previous display mode restored.'));
document.addEventListener('visibilitychange', () => { if (!document.hidden && !busy && !drag) reload(); });
setInterval(() => { if (!document.hidden && !busy && !drag) reload(); }, 8000);
setInterval(() => {
  renderPreview();
  if (!document.hidden && !busy && preview && preview.expires_at < Date.now() / 1000) reload();
}, 1000);
reload();
