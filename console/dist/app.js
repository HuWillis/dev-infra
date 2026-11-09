'use strict';
const token = document.querySelector('meta[name="console-token"]').content;
const $ = (selector) => document.querySelector(selector);
const escapeHTML = (value) => String(value ?? '').replace(/[&<>"']/g, char => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[char]));
const labels = {running:'运行中',stopped:'已停止',missing:'首次需下载',ready:'待启动',starting:'启动中',stopping:'停止中',partial:'部分运行',unhealthy:'状态异常',offline:'引擎离线'};
const selected = new Set();
let state = null, view = 'services', filter = 'all', query = '', category = 'all', fetching = false, cardSignature = '', stackSignature = '', historySignature = '';
let detailService = null, logService = null, toastTimer = null, secretTimer = null;

async function api(path, data) {
  const options = {headers:{'X-Console-Token':token},cache:'no-store'};
  if (data !== undefined) { options.method='POST'; options.headers['Content-Type']='application/json'; options.body=JSON.stringify(data); }
  let response;
  try { response = await fetch(path, options); } catch { throw new Error('暂时无法连接操作台。请双击桌面“本地开发操作台”重新打开。'); }
  const result = await response.json();
  if (!response.ok) throw new Error(response.status===403 ? '操作台会话已更新，请刷新浏览器页面。' : (result.error || '操作没有完成，请重试。'));
  return result;
}
function toast(message, error=false) { const element=$('#toast'); (document.querySelector('dialog[open]') || document.body).append(element); element.textContent=message; element.classList.toggle('error',error); element.classList.remove('hidden'); clearTimeout(toastTimer); toastTimer=setTimeout(()=>element.classList.add('hidden'),error?6500:2600); }
async function copy(value) {
  try { await navigator.clipboard.writeText(value); toast('已复制到剪贴板'); }
  catch { throw new Error('浏览器未允许剪贴板访问。请允许此页面使用剪贴板后重试。'); }
}
const activeJob = () => state?.jobs.find(job=>job.status==='running');
const serviceById = id => state?.services.find(service=>service.id===id);
const names = ids => ids.map(id=>serviceById(id)?.name || id).join('、');
const dateLabel = timestamp => new Date(timestamp*1000).toLocaleString('zh-CN',{hour12:false});
function effectiveState(service) { const job=activeJob(); return job?.services.includes(service.id) ? job.action==='start'?'starting':'stopping' : service.state; }
function statusHTML(status) { return `<span class="status status-${escapeHTML(status)}"><span class="dot"></span>${escapeHTML(labels[status]||status)}</span>`; }
function visibleServices() {
  return (state?.services || []).filter(service=>
    (category==='all' || service.category===category) &&
    (!query || [service.name,service.purpose,service.category,...service.ports.map(p=>p.address)].join(' ').toLowerCase().includes(query)) &&
    (filter==='all' || (filter==='running' ? ['running','partial','unhealthy','starting'].includes(service.state) : !['running','partial','unhealthy','starting'].includes(service.state))));
}

function renderServices(force=false) {
  if (!state) return;
  const busy=Boolean(activeJob()), offline=!state.engine.online;
  const signature=JSON.stringify([state.services,activeJob()?.id,filter,query,category,[...selected]]);
  if (!force && signature===cardSignature) return;
  cardSignature=signature;
  const services=visibleServices();
  $('#service-grid').innerHTML = services.length ? services.map(service=>{
    const status=effectiveState(service), running=['running','starting','partial','unhealthy'].includes(service.state);
    return `<article class="service-card ${selected.has(service.id)?'selected':''}" data-service="${service.id}">
      <div class="card-body"><div class="card-top"><div class="service-identity"><div class="service-logo logo-${service.id}">${service.icon}</div><div><h2 class="service-title">${service.name}</h2><span class="service-version" title="${escapeHTML(service.version)}">${escapeHTML(service.version)}</span></div></div><input class="card-select" type="checkbox" data-select="${service.id}" aria-label="选择 ${service.name}" ${selected.has(service.id)?'checked':''}></div>
      <p class="service-description">${service.purpose}</p>${service.dependencies.length?`<p class="dependency-note">自动带起 ${escapeHTML(names(service.dependencies))}</p>`:''}<div class="service-address"><span>${escapeHTML(service.ports[0].address)}</span><button class="copy-button" data-copy="${escapeHTML(service.ports[0].address)}" aria-label="复制 ${service.name} 地址" title="复制地址">⧉</button></div>
      <div class="card-status-row">${statusHTML(status)}<button class="text-button" data-action="logs" data-service="${service.id}">查看日志 ↗</button></div></div>
      <div class="card-footer"><button class="button primary" data-action="start" data-service="${service.id}" ${busy||offline||service.state==='running'?'disabled':''}><span>▷</span>启动</button><button class="button" data-action="stop" data-service="${service.id}" ${busy||offline||!running?'disabled':''}>停止</button><button class="button connection-button" data-action="details" data-service="${service.id}">连接信息 <span>→</span></button></div>
    </article>`;
  }).join('') : '<div class="empty-state"><strong>没有匹配的服务</strong>试试其他名称、用途或运行状态。</div>';
  $('#selection-toolbar').classList.toggle('hidden',!selected.size);
  $('#selection-label').textContent=`已选择 ${selected.size} 个中间件`;
  for (const button of document.querySelectorAll('[data-action="start-selected"],[data-action="stop-selected"]')) button.disabled=busy||offline;
  const checkbox=$('#select-all'); checkbox.checked=Boolean(services.length)&&services.every(service=>selected.has(service.id)); checkbox.indeterminate=!checkbox.checked&&services.some(service=>selected.has(service.id));
}

function renderStacks(force=false) {
  if (!state) return;
  const signature=JSON.stringify([state.stacks,Boolean(activeJob()),state.engine.online]);
  if (!force && signature===stackSignature) return;
  stackSignature=signature;
  const descriptions={base:'基础开发',search:'搜索项目',mongo:'文档应用',microservice:'微服务项目',storage:'文件存储','java-web':'Java Web 开发',jobs:'任务调度','search-console':'搜索与管理','rocketmq-console':'消息与管理',observability:'指标与看板','microservice-governance':'微服务治理',streaming:'事件流','postgres-app':'PostgreSQL 项目'};
  $('#stack-grid').innerHTML=Object.entries(state.stacks).map(([name,services])=>`<article class="stack-card"><div class="stack-card-header"><h3>${escapeHTML(name)}</h3><button class="text-button" data-action="edit-stack" data-stack="${escapeHTML(name)}">编辑组合 ↗</button></div><p class="detail-caption">${descriptions[name]||'自定义项目组合'} · ${services.length} 个中间件</p><div class="stack-chip-list">${services.map(id=>`<span class="stack-chip">${escapeHTML(serviceById(id)?.name || id)}</span>`).join('')}</div><div class="stack-actions"><button class="button primary" data-action="start-stack" data-stack="${escapeHTML(name)}" ${activeJob()||!state.engine.online?'disabled':''}>▷ 启动组合</button><button class="button" data-action="stop-stack" data-stack="${escapeHTML(name)}" ${activeJob()||!state.engine.online?'disabled':''}>停止组合</button></div></article>`).join('');
}

function renderHistory(force=false) {
  if (!state) return;
  const signature=JSON.stringify(state.jobs);
  if (!force && signature===historySignature) return;
  historySignature=signature;
  const open=new Set([...document.querySelectorAll('.history-card details[open]')].map(element=>element.dataset.job));
  const statuses={running:'执行中',success:'已完成',failed:'未完成',interrupted:'已中断'};
  $('#history-list').innerHTML=state.jobs.length ? state.jobs.map(job=>`<article class="history-card"><div class="history-title"><span>${job.action==='start'?'启动':'停止'} ${escapeHTML(names(job.services))}</span><span class="status ${job.status==='success'?'status-running':job.status==='failed'?'status-unhealthy':'status-starting'}"><span class="dot"></span>${statuses[job.status]}</span></div><time>${dateLabel(job.startedAt)}</time><details data-job="${job.id}" ${open.has(job.id)?'open':''}><summary>查看执行详情</summary><pre>${escapeHTML(job.output || '等待输出…')}</pre></details></article>`).join('') : '<div class="empty-state"><strong>还没有操作记录</strong>启动或停止中间件后，结果会保存在这里。</div>';
}

function renderJobBanner() {
  const banner=$('#job-banner'), job=activeJob();
  banner.classList.toggle('hidden',!job);
  if (job) banner.innerHTML=`<span class="spinner"></span><div>正在${job.action==='start'?'启动':'停止'} ${escapeHTML(names(job.services))}<small>${job.action==='start'?'首次启动会下载镜像，服务就绪后状态会自动更新。':'正在停止服务，已有数据会保留。'}</small></div><button class="text-button" data-action="job-details">查看进度 →</button>`;
}

async function refresh(force=false) {
  if (fetching) return;
  fetching=true;
  try {
    const previous=activeJob();
    state=await api('/api/state');
    $('#workspace-root').textContent=state.root;
    $('#connection-error').classList.add('hidden');
    const engine=$('#engine-badge'); engine.classList.toggle('online',state.engine.online); engine.innerHTML=`<span class="dot"></span>${state.engine.online?'Docker 已连接':'Docker 未连接'}`;
    $('#engine-error').classList.toggle('hidden',state.engine.online); $('#engine-error').textContent=state.engine.online?'':`无法连接本机 Docker。请先打开 Docker Desktop 或 Rancher Desktop（Moby）。\n${state.engine.error || ''}`;
    const running=state.services.filter(service=>service.state==='running').length, installed=state.services.filter(service=>service.imagePresent).length;
    $('#nav-service-count').textContent=state.services.length; $('#filter-service-count').textContent=state.services.length;
    const categoryOptions=['all',...new Set(state.services.map(s=>s.category))];
    if ($('#category-filter').options.length!==categoryOptions.length) $('#category-filter').innerHTML=categoryOptions.map(c=>`<option value="${escapeHTML(c)}">${c==='all'?'全部用途':escapeHTML(c)}</option>`).join('');
    $('#category-filter').value=category;
    $('#running-count').innerHTML=`${running}<small> / ${state.services.length}</small>`;
    $('#installed-count').innerHTML=`${installed}<small> 个镜像</small>`;
    $('#missing-count').innerHTML=`${state.services.length-installed}<small> 个服务</small>`;
    $('#updated-at').textContent=`更新于 ${new Date(state.updatedAt*1000).toLocaleTimeString('zh-CN',{hour12:false})}`;
    renderServices(force); renderStacks(force); renderHistory(force); renderJobBanner();
    if (previous && !activeJob()) {
      const finished=state.jobs.find(job=>job.id===previous.id);
      if (finished) toast(finished.status==='success'?'操作已完成': '操作未完成，请在“操作记录”查看原因。',finished.status!=='success');
    }
  } catch (error) { $('#connection-error').textContent=error.message; $('#connection-error').classList.remove('hidden'); }
  finally { fetching=false; }
}

function showView(next) {
  view=next;
  const titles={services:['中间件','所有环境，触手可及。','数据库、缓存与消息队列，按项目需要轻松启停。'],stacks:['项目组合','一个项目，一键就绪。','把常用中间件收进组合，下次开发从一次点击开始。'],history:['操作记录','每次操作，都有回响。','查看执行进度与结果，出错时也能找到原因。']};
  document.querySelectorAll('[data-view]').forEach(button=>button.classList.toggle('active',button.dataset.view===next));
  ['services','stacks','history'].forEach(name=>$(`#${name}-view`).classList.toggle('hidden',name!==next));
  $('#breadcrumb-current').textContent=titles[next][0]; $('#page-title').textContent=titles[next][1]; $('#page-subtitle').textContent=titles[next][2]; $('#new-stack-button').classList.toggle('hidden',next!=='stacks');
  if (next==='history') renderHistory();
}

async function startAction(action, services) {
  if (!services.length) return toast('请先选择中间件');
  if (activeJob()) return toast('请等当前操作完成');
  const job=await api('/api/jobs',{action,services});
  state.jobs.unshift(job); renderJobBanner(); renderServices(true); renderStacks(true); renderHistory(true);
  toast(`${action==='start'?'启动':'停止'}任务已开始`);
  await refresh(true);
}

function openDetails(id) {
  const service=serviceById(id); if (!service) return;
  detailService=id; clearTimeout(secretTimer);
  $('#detail-title').textContent=service.name;

  $('#detail-content').innerHTML=`<div class="detail-intro"><div class="service-logo logo-${id}">${service.icon}</div><div>${statusHTML(effectiveState(service))}<p>${service.purpose}</p></div></div>
    <section class="detail-section"><h3>本地地址与端口</h3>${service.ports.map(port=>`<div class="detail-port"><span>${escapeHTML(port.label)}</span><code>${escapeHTML(port.address)}</code><button class="copy-button" data-copy="${escapeHTML(port.address)}" aria-label="复制 ${escapeHTML(port.label)} 地址">⧉</button></div>`).join('')}</section>
    ${service.links.length?`<section class="detail-section"><h3>快捷链接</h3><div class="detail-links">${service.links.map(link=>`<a href="${escapeHTML(link.url)}" target="_blank" rel="noopener noreferrer">${escapeHTML(link.label)}<span>↗</span></a><p class="detail-caption">${escapeHTML(link.url)}</p>`).join('')}</div></section>`:''}
    <section class="detail-section"><h3>账号与密码</h3>${service.accounts.map(account=>`<div class="account-block"><div class="account-label">${escapeHTML(account.label)}</div><div class="credential-row"><span>用户名</span><code>${escapeHTML(account.username)}</code><button class="copy-button" data-copy="${escapeHTML(account.username)}" aria-label="复制 ${escapeHTML(account.label)} 用户名">⧉</button></div><div class="credential-row"><span>密码 / Token</span><input class="credential-value" id="password-${account.id}" aria-label="${escapeHTML(account.label)} 密码" type="password" readonly placeholder="••••••••••••"><button class="reveal-button" data-action="reveal" data-account="${account.id}" aria-label="显示 ${escapeHTML(account.label)} 密码">显示</button><button class="copy-button" data-action="copy-password" data-account="${account.id}" aria-label="复制 ${escapeHTML(account.label)} 密码">⧉</button></div></div>`).join('') || '<p class="detail-caption">当前配置无需账号密码。</p>'}<p class="detail-caption">${escapeHTML(service.notes)}</p>${service.accounts.length?'<p class="detail-caption">读取本机配置 · 密码显示 60 秒后自动隐藏<br>现有数据卷中的实际密码，以初始化时的配置为准。</p>':''}</section>
    <section class="detail-section"><h3>应用连接</h3><button class="button full-width" data-action="copy-connection">⧉ 复制${service.connectionHasPassword?'完整连接串（含密码）':'连接地址'}</button><p class="detail-caption">${id==='minio'?'S3 Endpoint 不包含密钥，请另行复制上方 Access Key 与 Secret Key。':id==='rocketmq'?'复制的是 NameServer 地址；Proxy gRPC 地址见上方端口列表。':'地址用于 Windows / macOS 本机应用；具体接入方式见下方说明。'}</p></section>
    ${service.dependencies.length?`<section class="detail-section"><h3>启动依赖</h3><p class="detail-caption">自动启动 ${escapeHTML(names(service.dependencies))}。停止当前服务会保留依赖；若需一起停止，请同时勾选。</p></section>`:''}
    ${service.integration?`<section class="detail-section"><h3>项目接入示例</h3><pre class="integration-example">${escapeHTML(service.integration)}</pre><button class="button small" data-copy="${escapeHTML(service.integration)}">⧉ 复制示例</button></section>`:''}
    <section class="detail-section"><h3>镜像</h3><div class="detail-image">${escapeHTML(service.image)}</div></section>`;
  $('#detail-dialog').showModal();
}

function clearSecrets() {
  clearTimeout(secretTimer);
  $('#detail-dialog').querySelectorAll('.credential-value').forEach(input=>{input.value='';input.type='password';});
  $('#detail-dialog').querySelectorAll('[data-action="reveal"]').forEach(button=>{button.textContent='显示';});
}
async function reveal(button) {
  const input=$(`#password-${button.dataset.account}`);
  if (input.type==='text') { input.value=''; input.type='password'; button.textContent='显示'; return; }
  const requestedService=detailService;
  const credential=await api('/api/credentials',{service:requestedService,account:button.dataset.account});
  if (detailService!==requestedService || !$('#detail-dialog').open) return;
  input.value=credential.password; input.type='text'; button.textContent='隐藏'; clearTimeout(secretTimer); secretTimer=setTimeout(clearSecrets,60000);
}

async function openLogs(id) {
  logService=id; $('#log-title').textContent=`${serviceById(id)?.name || id} 日志`; $('#log-caption').textContent='最近 120 行 · 密码已隐藏'; $('[data-action="refresh-logs"]').classList.remove('hidden'); $('#log-text').textContent='正在读取…'; if (!$('#log-dialog').open) $('#log-dialog').showModal();
  try { const result=await api(`/api/logs?service=${encodeURIComponent(id)}`); if (logService===id) $('#log-text').textContent=result.text.trim() || '还没有日志。首次启动该中间件后可在这里查看。'; }
  catch (error) { $('#log-text').textContent=error.message; }
}

function editStack(name='') {
  if (!state) return;
  $('#stack-title').textContent=name?'编辑项目组合':'新建项目组合'; $('#stack-name').value=name; $('#stack-name').readOnly=Boolean(name); $('#stack-form-error').classList.add('hidden');
  const services=state.stacks[name] || [];
  $('#stack-options').innerHTML=state.services.map(service=>`<label class="stack-option"><input type="checkbox" name="stack-service" value="${service.id}" ${services.includes(service.id)?'checked':''}>${service.name}</label>`).join('');
  $('#stack-dialog').showModal();
}

document.addEventListener('click',async event=>{
  const target=event.target.closest('button,[data-copy]'); if (!target) return;
  try {
    if (target.dataset.view) return showView(target.dataset.view);
    if (target.dataset.filter) { filter=target.dataset.filter; document.querySelectorAll('[data-filter]').forEach(button=>button.classList.toggle('active',button===target)); return renderServices(true); }
    if (target.dataset.copy!==undefined) return await copy(target.dataset.copy);
    const action=target.dataset.action, service=target.dataset.service;
    switch(action) {
      case 'refresh': return await refresh(true);
      case 'start': case 'stop': return await startAction(action,[service]);
      case 'start-selected': case 'stop-selected': return await startAction(action.startsWith('start')?'start':'stop',[...selected]);
      case 'clear-selection': selected.clear(); return renderServices(true);
      case 'details': return openDetails(service);
      case 'close-detail': return $('#detail-dialog').close();
      case 'logs': return await openLogs(service);
      case 'refresh-logs': return await openLogs(logService);
      case 'close-logs': return $('#log-dialog').close();
      case 'reveal': return await reveal(target);
      case 'copy-password': { const credential=await api('/api/credentials',{service:detailService,account:target.dataset.account}); return await copy(credential.password); }
      case 'copy-connection': { const connection=await api('/api/connection-string',{service:detailService}); return await copy(connection.value); }
      case 'start-stack': case 'stop-stack': return await startAction(action.startsWith('start')?'start':'stop',state.stacks[target.dataset.stack]);
      case 'new-stack': return editStack();
      case 'edit-stack': return editStack(target.dataset.stack);
      case 'close-stack': return $('#stack-dialog').close();
      case 'job-details': { showView('history'); const job=activeJob(); const details=job&&document.querySelector(`details[data-job="${job.id}"]`); if (details) details.open=true; return; }
    }
  } catch(error) { toast(error.message,true); }
});
$('#service-search').addEventListener('input',event=>{query=event.target.value.trim().toLowerCase();renderServices(true);});
$('#category-filter').addEventListener('change',event=>{category=event.target.value;renderServices(true);});
document.addEventListener('change',event=>{
  if (event.target.dataset.select) { const id=event.target.dataset.select; if (event.target.checked) selected.add(id); else selected.delete(id); renderServices(true); }
  if (event.target.id==='select-all') { for (const service of visibleServices()) { if (event.target.checked) selected.add(service.id); else selected.delete(service.id); } renderServices(true); }
});
$('#detail-dialog').addEventListener('close',()=>{ clearSecrets(); detailService=null; $('#detail-content').replaceChildren(); });
$('#stack-form').addEventListener('submit',async event=>{
  event.preventDefault();
  const services=[...document.querySelectorAll('input[name="stack-service"]:checked')].map(input=>input.value);
  const button=$('#stack-form button[type="submit"]'); button.disabled=true;
  try { if (!services.length) throw new Error('请至少选择一个中间件。'); await api('/api/stacks',{name:$('#stack-name').value.trim(),services}); $('#stack-dialog').close(); toast('项目组合已保存'); await refresh(true); }
  catch(error) { $('#stack-form-error').textContent=error.message; $('#stack-form-error').classList.remove('hidden'); }
  finally { button.disabled=false; }
});
document.addEventListener('visibilitychange',()=>{ if (document.hidden) clearSecrets(); else refresh(); });
refresh();
setInterval(()=>{if(!document.hidden)refresh();},4000);
