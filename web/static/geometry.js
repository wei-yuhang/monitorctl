export function connected(screens) {
  if (!screens.length) return false;
  const links = screens.map(() => []);
  for (let i = 0; i < screens.length; i++) {
    const a = screens[i];
    for (let j = i + 1; j < screens.length; j++) {
      const b = screens[j];
      const x = Math.min(a.x + a.width, b.x + b.width) - Math.max(a.x, b.x);
      const y = Math.min(a.y + a.height, b.y + b.height) - Math.max(a.y, b.y);
      if (x > 0 && y > 0) return false;
      if ((x > 0 && y === 0) || (y > 0 && x === 0)) {
        links[i].push(j);
        links[j].push(i);
      }
    }
  }
  const visited = new Set([0]);
  for (const i of visited) for (const j of links[i]) visited.add(j);
  return visited.size === screens.length;
}

export function place(screen, anchor, side) {
  if (side === 'left') return {x: anchor.x - screen.width, y: anchor.y};
  if (side === 'right') return {x: anchor.x + anchor.width, y: anchor.y};
  if (side === 'above') return {x: anchor.x, y: anchor.y - screen.height};
  return {x: anchor.x, y: anchor.y + anchor.height};
}

export function snap(screens, uuid, point) {
  const screen = screens.find(d => d.uuid === uuid);
  const others = screens.filter(d => d.uuid !== uuid);
  const candidates = [];
  for (const anchor of others) {
    for (const side of ['left', 'right', 'above', 'below']) {
      const aligned = place(screen, anchor, side);
      const vertical = side === 'left' || side === 'right';
      const axis = vertical ? 'y' : 'x';
      const size = vertical ? 'height' : 'width';
      const overlap = Math.min(screen[size], anchor[size], 40);
      const lo = anchor[axis] - screen[size] + overlap;
      const hi = anchor[axis] + anchor[size] - overlap;
      const offsets = [
        Math.round(Math.max(lo, Math.min(hi, point[axis]))),
        anchor[axis],
        anchor[axis] + anchor[size] - screen[size],
        ...others.flatMap(other => [other[axis] - screen[size], other[axis] + other[size]]),
      ];
      for (const offset of offsets) {
        if (offset < lo || offset > hi) continue;
        const target = {...aligned, [axis]: offset};
        if (connected([...others, {...screen, ...target}])) candidates.push(target);
      }
    }
  }
  candidates.sort((a, b) => Math.hypot(a.x - point.x, a.y - point.y) - Math.hypot(b.x - point.x, b.y - point.y));
  return candidates[0] ?? null;
}

export function makeMain(screens, uuid) {
  const screen = screens.find(d => d.uuid === uuid);
  return screens.map(d => ({...d, main: d.uuid === uuid, x: d.x - screen.x, y: d.y - screen.y}));
}
