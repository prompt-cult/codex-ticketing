-- codex-ticketing local web UI (about/stats + list/filter/create).
-- Served at GET /ui; talks to /api/tickets and /api/stats.

local M = {}

M.html = [[<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>codex-ticketing</title>
<style>
  :root { --bg:#0f1115; --panel:#171a21; --line:#2a2f3a; --tx:#e6e8ee; --mut:#8b93a5; --acc:#4f8cff; }
  * { box-sizing:border-box; }
  body { margin:0; background:var(--bg); color:var(--tx); font:14px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif; }
  .wrap { max-width:980px; margin:0 auto; padding:24px; }
  h1 { font-size:20px; } h1 small { color:var(--mut); font-weight:400; }
  .stats { display:flex; gap:12px; flex-wrap:wrap; margin:16px 0; }
  .stat { background:var(--panel); border:1px solid var(--line); border-radius:8px; padding:10px 16px; }
  .stat b { display:block; font-size:22px; }
  .stat span { color:var(--mut); font-size:12px; }
  .filters, .form { background:var(--panel); border:1px solid var(--line); border-radius:8px; padding:12px; margin:12px 0; display:flex; gap:8px; flex-wrap:wrap; align-items:center; }
  input, select, button { background:#0d0f14; border:1px solid var(--line); color:var(--tx); border-radius:6px; padding:6px 10px; font:inherit; }
  button { background:var(--acc); border-color:var(--acc); color:#06101f; font-weight:600; cursor:pointer; }
  table { width:100%; border-collapse:collapse; background:var(--panel); border:1px solid var(--line); border-radius:8px; overflow:hidden; }
  th, td { text-align:left; padding:8px 12px; border-bottom:1px solid var(--line); vertical-align:top; }
  th { color:var(--mut); font-size:12px; text-transform:uppercase; letter-spacing:.04em; }
  tr:last-child td { border-bottom:0; }
  .tag { display:inline-block; padding:1px 8px; border-radius:99px; font-size:12px; background:#222836; color:var(--mut); }
  .tag.bug { background:#3a1f1f; color:#ff9c9c; } .tag.task { background:#1f2a3a; color:#9cc4ff; }
  .tag.feature { background:#223a22; color:#9cffb0; } .tag.chore { background:#33301f; color:#ffe29c; }
  .tag.milestone { background:#2e1f3a; color:#d3a8ff; } .tag.unknown { background:#222836; color:var(--mut); }
  .st { font-size:12px; } .st.pending{color:#ffc46b}.st.in_progress{color:#6ba9ff}.st.completed{color:#6bff9c}.st.cancelled{color:#ff7b7b}.st.superseded{color:#b0b6c4}
  .meta { color:var(--mut); font-size:12px; }
  .empty { color:var(--mut); padding:24px; text-align:center; }
  .err { color:#ff7b7b; padding:8px; }
</style>
</head>
<body>
<div class="wrap">
  <h1>codex-ticketing <small>local web UI</small></h1>

  <div class="stats" id="stats"><div class="stat"><span>loading…</span></div></div>

  <div class="form">
    <input id="f_todo" placeholder="todo (one line)" size="24">
    <input id="f_md" placeholder="md_content (spec body)" size="40">
    <input id="f_sid" placeholder="session_id" size="20">
    <select id="f_type">
      <option value="">type…</option>
      <option>unknown</option><option>task</option><option>bug</option>
      <option>feature</option><option>chore</option><option>milestone</option>
    </select>
    <button onclick="createTicket()">Create ticket</button>
  </div>

  <div class="filters">
    <input id="f_sid_filter" placeholder="session_id (empty = all)" size="24">
    <select id="f_status">
      <option value="">status…</option>
      <option>pending</option><option>in_progress</option><option>completed</option>
      <option>cancelled</option><option>superseded</option>
    </select>
    <select id="f_type_filter">
      <option value="">type…</option>
      <option>unknown</option><option>task</option><option>bug</option>
      <option>feature</option><option>chore</option><option>milestone</option>
    </select>
    <button onclick="loadTickets()">Apply</button>
  </div>

  <div id="err" class="err"></div>
  <table id="tbl"><thead><tr><th>#</th><th>type</th><th>status</th><th>todo</th><th>body</th><th>session</th><th>updated</th></tr></thead><tbody></tbody></table>
  <div class="empty" id="empty" style="display:none">no tickets</div>
</div>
<script>
const api = (p, o) => fetch(p, o).then(r => r.ok ? r.json() : Promise.reject(r.status + ' ' + r.statusText));
async function loadStats(){
  try {
    const s = await api('/api/stats');
    const el = document.getElementById('stats');
    el.innerHTML =
      stat('tickets', s.active) + stat('by type', Object.entries(s.by_type || {}).map(([k,v])=>k+':'+v).join(' · ')) +
      stat('by status', Object.entries(s.by_status || {}).map(([k,v])=>k+':'+v).join(' · ')) +
      stat('latest', (s.latest_created || '').slice(0,16));
  } catch(e){ document.getElementById('err').textContent = 'stats: ' + e; }
}
function stat(label, value){ return '<div class="stat"><b>'+value+'</b><span>'+label+'</span></div>'; }
async function loadTickets(){
  const sid = document.getElementById('f_sid_filter').value.trim();
  const status = document.getElementById('f_status').value;
  const type = document.getElementById('f_type_filter').value;
  let q = '/api/tickets?';
  if (sid) q += 'session_id=' + encodeURIComponent(sid) + '&';
  if (status) q += 'status=' + encodeURIComponent(status) + '&';
  if (type) q += 'type=' + encodeURIComponent(type) + '&';
  q += 'all=true';
  try {
    const rows = await api(q);
    const tb = document.querySelector('#tbl tbody');
    tb.innerHTML = '';
    document.getElementById('empty').style.display = rows.length ? 'none' : 'block';
    for (const t of rows){
      const tr = document.createElement('tr');
      tr.innerHTML =
        '<td>#' + t.id + '</td>' +
        '<td><span class="tag ' + t.type + '">' + t.type + '</span></td>' +
        '<td><span class="st ' + t.status + '">' + t.status + '</span></td>' +
        '<td>' + esc(t.todo) + '</td>' +
        '<td class="meta">' + esc((t.md_content||'').slice(0,160)) + '</td>' +
        '<td class="meta">' + esc(t.session_id) + '</td>' +
        '<td class="meta">' + esc((t.updated_at||'').slice(0,16)) + '</td>';
      tb.appendChild(tr);
    }
  } catch(e){ document.getElementById('err').textContent = 'list: ' + e; }
}
async function createTicket(){
  const body = {
    todo: document.getElementById('f_todo').value.trim(),
    md_content: document.getElementById('f_md').value,
    session_id: document.getElementById('f_sid').value.trim(),
    type: document.getElementById('f_type').value || 'unknown',
  };
  try {
    const r = await api('/api/tickets', { method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify(body) });
    if (r.error) { document.getElementById('err').textContent = r.error.code + ': ' + r.error.message; return; }
    document.getElementById('f_todo').value = ''; document.getElementById('f_md').value = '';
    loadTickets(); loadStats();
  } catch(e){ document.getElementById('err').textContent = 'create: ' + e; }
}
function esc(s){ return String(s == null ? '' : s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])); }
loadStats(); loadTickets();
</script>
</body>
</html>
]]

return M
