async function json(url, options={}) {
  const r = await fetch(url, options);
  const body = await r.json().catch(() => ({error:"invalid response"}));
  if (!r.ok) throw new Error(body.error || r.statusText);
  return body;
}
function setCard(name, ready, detail="") {
  const card = document.querySelector('[data-cap="'+name+'"]');
  if (!card) return;
  const s = card.querySelector('.status');
  s.className = 'status ' + (ready ? 'ready' : 'degraded');
  s.querySelector('span:last-child').textContent = ready ? 'ready' : 'degraded';
  if (detail) card.querySelector('.result').textContent = detail;
}
async function refresh() {
  try {
    const s = await json('/api/status');
    Object.entries(s.capabilities).forEach(([k,v]) => setCard(k, v.ready, v.detail || ''));
    const all = Object.values(s.capabilities).filter(v => !v.optional).every(v => v.ready);
    const badge = document.getElementById('overall');
    badge.textContent = all ? 'READY' : 'DEGRADED';
  } catch (e) {
    document.getElementById('overall').textContent = 'UNAVAILABLE';
  }
}
async function act(name) {
  const key = name === 'object' ? 'object_storage' : (name === 'runtime-resource' ? 'runtime_resource' : name);
  const card = document.querySelector('[data-cap="'+key+'"]');
  const out = card ? card.querySelector('.result') : null;
  try {
    const r = await json('/api/'+name, {method:'POST'});
    if (out) out.textContent = JSON.stringify(r, null, 2);
    await refresh();
  } catch (e) {
    if (out) out.textContent = e.message;
  }
}
async function scenario() {
  const out = document.getElementById('scenario');
  out.textContent = 'running...';
  const steps = ['sql','cache','object','trace','runtime-resource'];
  const lines = [];
  for (const step of steps) {
    try { await json('/api/'+step,{method:'POST'}); lines.push(step.toUpperCase()+' PASS'); }
    catch (e) { lines.push(step.toUpperCase()+' FAIL '+e.message); }
  }
  try { await json('/api/companion',{method:'POST'}); lines.push('COMPANION PASS'); }
  catch (e) { lines.push('COMPANION SKIP '+e.message); }
  out.textContent = lines.join('\n');
  refresh();
}
refresh();
setInterval(refresh, 10000);
