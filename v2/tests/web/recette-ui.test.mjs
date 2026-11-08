import { test, eq, ok } from './harness.mjs';
import { createSessionConnection, homePrerequisite, sessionContext, writePreparationAvailable } from '../../web/js/shell/session-flow.js';
import { render as renderHome } from '../../web/js/pages/accueil.js';
import { createOuPicker } from '../../web/js/pages/accueil/ou-picker.js';
import { createRefresh, stagePercent, OUTCOME } from '../../web/js/pages/accueil/refresh.js';
import { renderEmpty } from '../../web/js/pages/fiche/empty.js';
import { NOTHING_SENT } from '../../web/js/write-flow.js';
import { mockCall } from '../../web/js/mock.js';
import { widgetRefreshFeedback } from '../../web/js/pages/accueil/widget-result.js';

const delay = ms => new Promise(resolve => setTimeout(resolve, ms));

test('Actualisation des indicateurs : inconnu et partiel ne deviennent jamais un succès ; zéro mesuré reste valide', () => {
  const fresh={title:'Comptes actifs',measuredAt:new Date().toISOString(),stale:false,tone:'info',data:{value:0},detail:'Comptes du domaine'};
  eq(widgetRefreshFeedback(fresh).result,'ok','zéro réellement mesuré');
  for(const widget of [{...fresh,data:null},{...fresh,measuredAt:null},{...fresh,tone:'off'},{...fresh,stale:true}]) {
    eq(widgetRefreshFeedback(widget).tone,'warn','absence de succès inventé');
  }
});

test('Accueil : le bouton réel conserve le diagnostic sans mesure puis affiche le compteur reçu', async () => {
  const x=await fixtures();let dispose;const notices=[],refreshCalls=[];
  const summary=await mockCall('dashboard.summary');
  let result={...summary.widgets.activeAccounts,data:null,measuredAt:null,tone:'off',detail:'Lecture des comptes incomplète : aucun total du domaine.'};
  const ctx=await context(async(op,args)=>{
    if(op==='dashboard.widget.refresh'){refreshCalls.push(args);return result;}
    if(op==='accueil.refresh.state')return {running:false,last:null};
    return mockCall(op,args);
  },{toast:(text,options)=>notices.push({text,...options})});
  try {
    dispose=renderHome(x.host,ctx);
    const card=()=>x.host.querySelector('[data-widget="activeAccounts"]');
    await until(()=>card()?.querySelector('[data-refresh]:not(:disabled)'),'bouton du compteur absent');
    card().querySelector('[data-refresh]').click();
    await until(()=>notices.length===1,'résultat incomplet non signalé');
    eq(refreshCalls,[{id:'activeAccounts'}],'un seul geste pour le bon compteur');
    eq(notices[0].tone,'warn','aucune notification verte');
    ok(notices[0].text.includes('aucun total du domaine'),'diagnostic du moteur conservé');
    ok(!card().querySelector('[data-count="0"]'),'inconnu différent de zéro');
    eq(x.host.scrollWidth,x.host.clientWidth,'la vraie configuration d’infobulles ne crée pas de défilement horizontal');
    await capture('comptes-domaine-lecture-incomplete',{},card());
    result={...summary.widgets.activeAccounts,measuredAt:new Date().toISOString(),stale:false,tone:'info',data:{
      ...summary.widgets.activeAccounts.data,value:37,delta:null,history:[],
      breakdown:[{key:'enabled',label:'Actifs',value:37,tone:'ok'},{key:'disabled',label:'Désactivés',value:2,tone:'off'}],
    }};
    card().querySelector('[data-refresh]').click();
    await until(()=>notices.length===2,'compteur non actualisé');
    eq(refreshCalls,[{id:'activeAccounts'},{id:'activeAccounts'}],'aucune relance implicite');
    eq(notices[1].tone,'ok','réussite après donnée exploitable');
    ok(card().querySelector('[data-count="37"]'),'valeur reçue affichée');
    ok(card().textContent.includes('Actifs')&&card().querySelector('.stack-legend')?.textContent.includes('37'),'répartition cohérente avec le compteur reçu');
    ok(!card().textContent.includes('1186')&&!card().querySelector('.kpi-spark'),'aucun ancien effectif ou historique repris de la fixture');
    await capture('comptes-domaine-mesure-affichee',{},card());
  } finally {dispose?.();x.close();}
});
const deferred = () => { let resolve, reject; const promise = new Promise((a,b) => { resolve=a; reject=b; }); return {promise,resolve,reject}; };
async function until(check, label) { const end=Date.now()+8000; while(!check()) { if(Date.now()>end) throw new Error(label); await delay(20); } }
async function capture(name, facts = {}, target = null) {
  target?.scrollIntoView({block:'center',behavior:'instant'});
  await delay(1100);
  await new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));
  if(target){const r=rect(target);ok(r.x>=0&&r.y>=0&&r.right<=innerWidth&&r.bottom<=innerHeight,`capture entière : ${name}`);}
  if (!globalThis.__domeniaNativeVisualCapture) return;
  const host=document.querySelector('[data-recette-fixture]');
  globalThis.__domeniaVisualCapture = { name, facts:{...(typeof facts==='function'?facts():facts),
    viewport:{width:innerWidth,height:innerHeight,clientWidth:document.documentElement.clientWidth,dpr:devicePixelRatio},
    fixture:host?rect(host):null,target:target?rect(target):null,theme:document.documentElement.dataset.theme,motion:document.documentElement.dataset.motion} };
  await until(() => globalThis.__domeniaVisualCapture === null, `Capture native non acquittée : ${name}`);
}
const rect = element => { const r=element.getBoundingClientRect(); return {x:r.x,y:r.y,width:r.width,height:r.height,right:r.right,bottom:r.bottom}; };
const inside = (child,parent,label) => { const a=rect(child), b=rect(parent); ok(a.x>=b.x-1 && a.right<=b.right+1 && a.y>=b.y-1 && a.bottom<=b.bottom+1, label); };
const overlap = (a,b) => a.x<b.right && a.right>b.x && a.y<b.bottom && a.bottom>b.y;
const noTimers = { every: () => () => {} };
async function fixtures(page='accueil', extraStyles=[]) {
  const styles=[];
  for (const file of ['layout.css','components.css','kit.css','motion.css','shell.css','pages/accueil.css','pages/fiche.css',...extraStyles]) {
    const link=document.createElement('link'); link.rel='stylesheet'; link.href=new URL(`../../web/css/${file}`,import.meta.url).href;
    styles.push(link); const loaded=new Promise((resolve,reject) => {link.onload=resolve;link.onerror=()=>reject(new Error(`CSS non chargé : ${file}`));}); document.head.append(link); await loaded;
  }
  const attrs={theme:document.documentElement.dataset.theme,motion:document.documentElement.dataset.motion};
  const hadTips=document.documentElement.classList.contains('js-tips');
  document.documentElement.classList.add('js-tips'); // Real shell: its positioned tooltips replace the CSS fallback boxes.
  document.documentElement.dataset.theme='dark';document.documentElement.dataset.motion='rich';
  const host=document.createElement('main'); host.className='main';host.dataset.page=page;
  host.dataset.recetteFixture='';
  Object.assign(host.style,{position:'fixed',left:'0',top:'0',width:'min(1280px, 100vw)',height:'100vh',zIndex:'40',background:'var(--bg)',overflow:'auto',padding:'24px'});
  document.body.append(host);
  return {host, width:n=>host.style.width=`min(${n}px, 100vw)`, close(){host.remove();styles.forEach(s=>s.remove()); if(!hadTips)document.documentElement.classList.remove('js-tips'); for(const [key,value] of Object.entries(attrs)) {if(value===undefined)delete document.documentElement.dataset[key];else document.documentElement.dataset[key]=value;}}};
}
async function context(call, extra={}) {
  const app={...(await mockCall('app.info')),mode:'annuaire',webViewRuntime:'embarque',banner:null};
  return {call,app:Promise.resolve(app),params:{},pulse:noTimers,toast:()=>{},navigate:()=>{},go:()=>{},showConnection:()=>{},...extra};
}

 test('Recette : connexion partagée unique, fin physique et réessai après échec', async () => {
  let attempt=deferred();const calls=[];const states=[];const sessions=[];
  const connection=createSessionConnection({call:op=>{calls.push(op);return op==='session.connect'?attempt.promise:Promise.resolve({connection:{state:'connected'}});},onState:v=>states.push(v),onSession:s=>sessions.push(s)});
  const first=connection.connect(), second=connection.connect(); ok(first===second,'même promesse pour deux actions'); await delay(0);
  eq(calls,['session.connect'],'un seul essai physique');eq(connection.running(),true,'reste en cours');attempt.reject(Object.assign(new Error('Annulée'),{code:'operation.cancelled'})); await first.catch(()=>{});
  eq(connection.running(),false,'fin reçue');eq(sessions.length,0,'aucune session inventée');attempt=deferred();const retry=connection.connect();attempt.resolve({});await retry;
  eq(calls,['session.connect','session.connect','session.info'],'réessai volontaire et session effective relue');eq(states,[true,false,true,false],'un début et une fin par essai');
 });

test('Recette : prérequis séparés, interruption inconnue et progression réelle des étapes', () => {
  ok(NOTHING_SENT.has('write.sessionRequired'),'refus avant envoi non qualifié d’issue inconnue');
  eq(homePrerequisite(null).kind,'disconnected','absence de session');
  eq(homePrerequisite(null,true).kind,'connecting','attente active');
  eq(homePrerequisite({connection:{state:'connected'}}).kind,'scope','OU à choisir');
  eq(homePrerequisite({connection:{state:'connected'},scope:{dn:'OU=X'}}),null,'prérequis acquis, pas de collecte implicite');
  ok(sessionContext({scope:{dn:'OU=A'}})!==sessionContext({scope:{dn:'OU=B'}}),'contexte inclut OU');
  eq(stagePercent([{state:'done'},{state:'running'},{state:'waiting'}]),33,'attente ne vaut pas terminé');
  eq(writePreparationAvailable({connection:{state:'disconnected'},writePlanAvailable:true,writePolicy:'confirmationPerOperation'}),false,'aucun plan préparé sans session');
  eq(writePreparationAvailable({connection:{state:'connected'},readOnly:true,writePlanAvailable:true,writePolicy:'confirmationPerOperation'}),true,'lecture au repos ne cache pas les plans explicites');
  eq(OUTCOME.interrupted.label,'Interrompue, à vérifier','checkpoint non assimilé à arrêt utilisateur');
});

test('Recette mouvements : pictogrammes au repos stables, indicateurs réellement actifs conservés', async () => {
  const pages=['operations','schema','machine','poste','ecritures','parametres','rechercher','relations','audit','synchro','requetes'];
  const x=await fixtures('accueil',['write-flow.css',...pages.map(page=>`pages/${page}.css`)]);
  const cases=[
    ['operations','<i class="op-orbit"></i><i class="op-engine-ring"></i><i class="op-survey-ring"></i>',[['.op-orbit'],['.op-engine-ring'],['.op-survey-ring','::after']]],
    ['schema','<div class="sch-orbit"><i class="orb-ring"></i></div>',[['.orb-ring']]],
    ['machine','<div class="mac-avatar"><i class="mac-orbit"></i></div><div class="mac-level" data-state="active"><i class="mac-rank"></i></div>',[['.mac-orbit'],['.mac-rank','::after']]],
    ['poste','<i class="ps-vault"></i><div class="ps-shown" data-urgent="true"><i class="ps-countdown"></i></div>',[['.ps-vault','::after'],['.ps-countdown']]],
    ['ecritures','<div class="wfd-steps"></div>',[['.wfd-steps','::after']]],
    ['parametres','<i class="pr-about-logo"></i>',[['.pr-about-logo','::before']]],
    ['rechercher','<i class="rch-hero-icon"></i><i class="rch-field-ring"></i><i class="rch-orbit"></i>',[['.rch-hero-icon','::before'],['.rch-field-ring','::before'],['.rch-orbit']]],
    ['relations','<i class="rel-empty-orbit"></i><svg><circle class="rel-core-ring"></circle><circle class="rel-primary-ring"></circle><circle class="rel-flow"></circle></svg>',[['.rel-empty-orbit'],['.rel-core-ring'],['.rel-primary-ring'],['.rel-flow']]],
    ['audit','<div class="aud-empty-art"><i class="ring"></i></div>',[['.ring']]],
    ['synchro','<i class="sy-dial-orbit"></i>',[['.sy-dial-orbit']]],
    ['requetes','<div class="rq-drop-art"><i></i></div>',[['.rq-drop-art i']]],
    ['fiche','<div class="fi-avatar-wrap" data-presence="online"><i class="fi-presence-dot"></i></div><div class="fi-presence" data-state="online"><i class="fi-presence-pulse"></i></div>',[['.fi-avatar-wrap','::before'],['.fi-presence-dot','::after'],['.fi-presence-pulse','::after']]],
  ];
  try {
    for(const [page,html,checks] of cases){
      const specimen=document.createElement('section');specimen.className='main';specimen.dataset.page=page;specimen.innerHTML=html;x.host.append(specimen);
      for(const [selector,pseudo] of checks)eq(getComputedStyle(specimen.querySelector(selector),pseudo).animationName,'none',`${page} ${selector} au repos`);
    }
    const active=document.createElement('section');active.className='main';active.dataset.page='poste';
    active.innerHTML='<i class="brand-mark"></i><div class="wf-expiry late"><i class="wf-expiry-icon"></i></div><i class="ps-run-spin"></i><div class="wf-run"><div class="wf-orbit"><i></i></div></div>';x.host.append(active);
    eq(getComputedStyle(active.querySelector('.brand-mark'),'::before').animationName,'none','logo stable');
    eq(getComputedStyle(active.querySelector('.wf-expiry-icon')).animationName,'none','échéance lisible sans déplacement');
    for(const selector of ['.ps-run-spin','.wf-orbit i']){
      const style=getComputedStyle(active.querySelector(selector));ok(style.animationName!=='none'&&parseFloat(style.animationDuration)>0,`${selector} actif reste animé`);
    }
  } finally {x.close();}
});

test('Recette Accueil : avant, pendant et après connexion sans OU, aucun résumé ni collecte prématuré', async () => {
  const x=await fixtures(); let dispose; const calls=[]; let connecting=false;let connectRequests=0;
  let session={...(await mockCall('session.info')),connection:{state:'disconnected',label:'Annuaire non connecté'},scope:null,readOnly:true};
  const ctx=await context(async(op,args)=>{calls.push(op);if(op==='session.info')return session;if(op==='accueil.refresh.state')return {running:false,last:null};return mockCall(op,args);},{connecting:()=>connecting,connectSession:()=>{connectRequests++;}});
  try {
    dispose=renderHome(x.host,ctx);await until(()=>x.host.querySelector('[data-state="disconnected"]'),'prérequsis connexion absent');
    const widgetStyle=document.querySelector('link[data-query-widgets]');
    eq(widgetStyle?.href,new URL('../../web/css/pages/requetes-widgets.css',import.meta.url).href,'CSS des widgets résolu depuis son module');
    await until(()=>widgetStyle.sheet,'CSS des widgets réellement chargé');
    const hero=x.host.querySelector('[data-slot="hero"]');const connect=hero.querySelector('[data-act="connect"]');
    ok(connect&&!connect.disabled,'connexion disponible dans le bandeau');inside(connect,x.host,'connexion visible sans défilement');
    eq(connectRequests,0,'aucune connexion implicite');ok(!calls.includes('dashboard.summary'),'résumé refusé avant session');
    await capture('accueil-deconnecte-hero',{},hero);
    await capture('accueil-deconnecte',{},x.host.querySelector('.home-prerequisite'));
    connect.click();eq(connectRequests,1,'même action de connexion partagée');connecting=true;window.dispatchEvent(new CustomEvent('domenia:connection-state'));
    await until(()=>x.host.querySelector('.home-prerequisite[data-state="connecting"]'),'attente connexion non affichée');
    const waiting=hero.querySelector('[data-act="connect"]');ok(waiting.disabled&&waiting.textContent.includes('Connexion en cours'),'suivi visible désactivé');waiting.click();eq(connectRequests,1,'suivi ne relance pas la connexion');
    await capture('accueil-connexion-en-cours-hero',{},hero);
    await capture('accueil-connexion-en-cours',{},x.host.querySelector('.home-prerequisite'));
    session={...session,connection:{state:'connected',label:'Connecté'}};window.dispatchEvent(new CustomEvent('domenia:session',{detail:session}));connecting=false;window.dispatchEvent(new CustomEvent('domenia:connection-state'));
    await until(()=>x.host.querySelector('.home-prerequisite[data-state="scope"]'),'invitation OU absente');
    ok(x.host.querySelector('[data-slot="connection-actions"]').hidden,'connexion retirée une fois établie');
    ok(!calls.includes('dashboard.summary'),'pas de résumé sans OU');ok(!calls.some(op=>op==='accueil.refresh.run'),'aucune collecte implicite');await capture('accueil-connecte-sans-ou',{},x.host.querySelector('.home-prerequisite'));
  } finally {dispose?.();x.close();}
});

test('Recette sélecteur OU : connexion tardive, réessai explicite et rejet du résultat ancien', async () => {
  const x=await fixtures();let picker;let connecting=false;const calls=[];let pending=null;
  let session={...(await mockCall('session.info')),connection:{state:'disconnected'},scope:null};
  const ctx=await context(async(op,args)=>{calls.push(op);if(op==='directory.ou.children'&&pending)return pending.promise;return mockCall(op,args);},{connecting:()=>connecting});
  try {
    picker=createOuPicker({ctx,current:()=>({session,app:{mode:'annuaire'}}),onApplied:()=>{}});picker.open();await delay(60);
    eq(calls.filter(op=>op==='directory.ou.children').length,0,'aucun LDAP sans session');
    session={...session,connection:{state:'connected'}};window.dispatchEvent(new CustomEvent('domenia:session',{detail:session}));
    eq(calls.filter(op=>op==='directory.ou.children').length,0,'connexion ne lance pas de lecture implicite');
    const action=document.querySelector('[data-ou-session-action]');ok(action?.textContent.includes('Charger'),'action relire contexte à jour');action.click();
    await until(()=>document.querySelector('.k-tree [role="treeitem"]'),'arborescence non chargée');await capture('selecteur-ou-connecte');
    pending=deferred();session={...session,account:{login:'EXAMPLE\\autre'}};window.dispatchEvent(new CustomEvent('domenia:session',{detail:session}));
    document.querySelector('[data-ou-session-action]').click();await delay(0);
    session={...session,account:{login:'EXAMPLE\\troisieme'}};window.dispatchEvent(new CustomEvent('domenia:session',{detail:session}));
    pending.resolve({parent:{dn:'DC=old',name:'Ancien domaine'},children:[]});await delay(50);
    ok(!document.querySelector('.acc-ou')?.textContent.includes('Ancien domaine'),'ancien compte ne publie pas son résultat');
  } finally {picker?.destroy();x.close();}
});

test('Recette Accueil : la navigation reste dans la page en fenêtre basse sans défilement horizontal', async () => {
  const root=document.documentElement, previousLow=root.getAttribute('data-low'), hadTips=root.classList.contains('js-tips');
  const x=await fixtures();let dispose;
  const session={...(await mockCall('session.info')),connection:{state:'connected'}};
  const ctx=await context(async(op,args)=>op==='session.info'?session:mockCall(op,args));
  try {
    root.setAttribute('data-low','');root.dataset.motion='reduced';root.classList.add('js-tips');
    // Match the real shell width and its JS tooltip mode; hidden fallback tooltips also have layout boxes.
    Object.assign(x.host.style,{left:'72px',top:'92px',width:`${innerWidth-72}px`,height:`${innerHeight-92}px`,padding:'0'});
    dispose=renderHome(x.host,ctx);
    await until(()=>x.host.querySelector('.hero h1')&&x.host.querySelector('.card.fw'),'Accueil complet non rendu');
    await delay(1100);
    await new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));
    const page=x.host.querySelector('.home'),nav=x.host.querySelector('.acc-nav');
    const mainBox=rect(x.host),navBox=rect(nav);
    eq(Math.round(mainBox.width),innerWidth-72,'largeur du shell cohérente avec les mediaqueries et sa navigation latérale');
    ok(mainBox.right<=innerWidth,'le conteneur et sa barre de défilement restent dans le viewport');
    eq(x.host.scrollWidth,x.host.clientWidth,'aucun débordement horizontal dans le conteneur principal');
    eq(page.scrollWidth,page.clientWidth,'aucun débordement horizontal dans la page');
    ok(navBox.x>=mainBox.x-1&&navBox.right<=mainBox.x+x.host.clientWidth+1,'bande de navigation contenue des deux côtés');
  } finally {
    dispose?.();x.close();
    if(previousLow===null)root.removeAttribute('data-low');else root.setAttribute('data-low',previousLow);
    if(!hadTips)root.classList.remove('js-tips');
  }
});

const sha='0123456789abcdef'.repeat(4);
const stages=[{id:'backup',label:'Sauvegarde vérifiée de la base locale',detail:`SHA256 ${sha}`,state:'done'},
 {id:'directory',label:'Lecture AD de l’OU',detail:'Lecture en cours',state:'running'},
 {id:'commit',label:'Validation et stockage',detail:'En attente',state:'waiting'}];
const failed={id:'recette-failure',label:'Actualisation interrompue : refus de plage LDAP ; sauvegarde conservée',status:'error',resumable:true,stages:stages.map(s=>s.id==='directory'?{...s,state:'failed',detail:'Attribut member : plage non contiguë. Aucune valeur sensible dans ce diagnostic.'}:s.id==='commit'?{...s,state:'skipped'}:s),runs:[]};

test('Campagne par branches : choix explicite, aucune collecte vide, un seul plan ciblé et temps réels séparés', async () => {
  const x=await fixtures(); let refresh; const calls=[];
  const scope={label:'Postes',dn:'OU=Postes,DC=example,DC=local',subtree:true};
  const branches=['Est','Ouest'].map(label=>({scope:{label,dn:`OU=${label},${scope.dn}`,subtree:true},targets:50000}));
  const plan={id:'large-all',title:'Actualiser le parc',summary:'Annuaire puis postes choisis',scope,stages:[],targets:100000,online:0,reused:0,warnings:[],confirm:'Lancer',estimateText:'Estimation',branches:[],availableBranches:branches,branchCount:2};
  const methods=['Ping','Ldap','WmiDcom','WinRm','Registry','ScheduledTask','PsExec','WindowsSessions','SecurityLog','WindowsRpc','WmiProcess','WinRmScript'];
  const report={id:'large-selected',label:'Collecte terminée',status:'success',stages:[],runs:[],branches:[{...branches[0],presenceDone:50000,inventoryDone:100}],branchCount:1,
    performance:{totalMs:1250,workstationsReused:42,methods:methods.map(method=>({method,label:method==='Ping'?'Réseau / ICMP':method==='WmiProcess'?'Programme local / WMI':method==='WinRmScript'?'Programme local / WinRM':method,reads:50000,cacheHits:0,queueMs:2000,executionMs:3000}))}};
  let state={running:false,last:null};
  const ctx=await context(async(op,args)=>{calls.push({op,args});if(op==='accueil.refresh.state')return state;if(op==='accueil.refresh.plan')return args.branches?{...plan,id:'large-selected',branches:args.branches,targets:50000}:plan;if(op==='accueil.refresh.run'){state={running:false,last:report};return report;}return {};});
  try {
    x.host.innerHTML='<div class="hero-actions"></div><div class="hero-status"></div>';
    refresh=createRefresh({actions:x.host.querySelector('.hero-actions'),status:x.host.querySelector('.hero-status'),ctx,scopeOk:()=>true,onFinished:async()=>true});
    x.host.querySelector('[data-refresh-mode="all"]').click();
    await until(()=>document.querySelector('[data-collect-branch]'),'branches absentes du plan');
    const dialog=[...document.querySelectorAll('[role="dialog"]')].at(-1), choices=[...dialog.querySelectorAll('[data-collect-branch]')];
    choices.forEach(input=>{input.checked=false;input.dispatchEvent(new Event('change',{bubbles:true}));});
    ok(dialog.querySelector('[data-id="run"]').disabled,'aucun lancement sans branche');
    choices[0].checked=true;choices[0].dispatchEvent(new Event('change',{bubbles:true}));
    dialog.querySelector('[data-id="run"]').click();
    await until(()=>calls.some(c=>c.op==='accueil.refresh.run'),'campagne non lancée');
    eq(calls.filter(c=>c.op==='accueil.refresh.plan').at(-1).args.branches,[branches[0].scope],'branche exacte transmise, pas liste de 50 000 identités');
    eq(calls.filter(c=>c.op==='accueil.refresh.run').map(c=>c.args.planId),['large-selected'],'une seule collecte du plan ciblé');
    await until(()=>x.host.querySelector('.ctl-performance')?.textContent.includes('Réseau / ICMP'),'bilan par méthode absent');
    ok(x.host.querySelector('.ctl-performance').textContent.includes('Attente cumulée'),'attente distinguée');
    ok(x.host.querySelector('.ctl-performance').textContent.includes('Exécution cumulée'),'exécution distinguée');
    eq(x.host.querySelectorAll('.ctl-performance tbody tr').length,12,'les douze méthodes restent visibles sans DOM de 100 000 lignes');
    ok(x.host.querySelector('.ctl-performance').textContent.includes('Programme local / WMI'),'WMI ponctuel distinct du CIM direct');
    ok(x.host.querySelector('.ctl-performance').textContent.includes('Programme local / WinRM'),'WinRM ponctuel non tronqué en fin de liste');
  } finally {refresh?.destroy();x.close();}
});

test('Recette actualisation : preuve intégrale, états en cours/erreur/reprise et une notification par tentative', async () => {
  const x=await fixtures();let refresh;const notices=[];const calls=[];const pulseCallbacks=[];
  let state={running:true,current:{id:'recette-running',label:'Première lecture de l’OU choisie',stages},last:null};
  const plan={id:'recette-plan',title:'Relire la base locale de l’OU',summary:'Lecture bornée de l’OU choisie',scope:{label:'Postes',dn:'OU=Postes,DC=example,DC=local',subtree:true},stages,targets:2,online:0,reused:0,warnings:[],confirm:'Lancer',estimateText:'Durée à mesurer'};
  const ctx=await context(async(op,args)=>{calls.push({op,args});if(op==='accueil.refresh.state')return state;if(op==='accueil.refresh.plan')return plan;if(op==='accueil.refresh.run'){state={running:false,last:failed};return failed;}return {};},{toast:(text,o)=>notices.push({text,o}),pulse:{every:(n,i,cb)=>{pulseCallbacks.push(cb);return ()=>{};}}});
  try {
    x.host.innerHTML='<div class="hero"><div class="hero-actions"></div><div class="hero-status"></div></div>';
    refresh=createRefresh({actions:x.host.querySelector('.hero-actions'),status:x.host.querySelector('.hero-status'),ctx,scopeOk:()=>true,onFinished:async()=>{throw Object.assign(new Error('Rendu indisponible'),{code:'source.unavailable'});}});
    await until(()=>x.host.querySelector('.ctl-stage'),'étapes absentes');
    eq(x.host.querySelector('.ctl-bar').getAttribute('aria-valuenow'),'33','pas de 100% inventé');
    const widths=[];
    for(const width of [1280,1024,800]){x.width(width);await delay(60);widths.push({requested:width,effective:rect(x.host).width});for(const span of x.host.querySelectorAll('.ctl-st span'))inside(span,span.closest('.ctl-stage'),'preuve contenue dans sa carte');ok(x.host.textContent.includes(sha),'SHA complet conservé');}
    await capture('actualisation-en-cours-sha',()=>({sha,widths,stageRectangles:[...x.host.querySelectorAll('.ctl-stage')].map(rect)}));
    state={running:false,last:failed};await pulseCallbacks.at(-1)();
    // The stages of the interrupted run stay displayed: « Étapes » says so and only a click on a folded list unfolds it.
    {const details=x.host.querySelector('[data-refresh-details]');eq(details.getAttribute('aria-expanded'),String(!x.host.querySelector('.ctl-run').hidden),'chevron conforme aux étapes affichées');if(details.getAttribute('aria-expanded')!=='true')details.click();}
    ok(!x.host.querySelector('.ctl-run').hidden,'étapes de la tentative interrompue affichées');await capture('actualisation-interrompue');
    const run=refresh.plan('resume');await until(()=>document.querySelector('.k-dlg-foot [data-id="run"]'),'confirmation reprise absente');await capture('reprise-confirmation');document.querySelector('.k-dlg-foot [data-id="run"]').click();await run;
    await until(()=>notices.length>0&&!refresh.running(),'reprise non terminée');
    eq(calls.filter(c=>c.op==='accueil.refresh.run').length,1,'une tentative réelle');eq(notices.filter(n=>n.o.key==='refresh:recette-failure').length,1,'une notification pour ce reçu malgré rendu échoué');
    ok(!calls.some(c=>c.op==='accueil.refresh.drawn'),'rendu échoué non acquitté');eq(x.host.querySelector('.ctl-stage[data-state="done"] .ctl-st span').textContent,`SHA256 ${sha}`,'sauvegarde acquise conservée');
    await capture('actualisation-erreur-rendu-conserve');
    refresh.destroy();
    const completed={...failed,id:'recette-success',status:'success',label:'Actualisation terminée',resumable:false,stages:stages.map(s=>({...s,state:'done',detail:s.id==='backup'?`SHA256 ${sha}`:'Étape vérifiée'}))};
    state={running:false,last:completed};
    refresh=createRefresh({actions:x.host.querySelector('.hero-actions'),status:x.host.querySelector('.hero-status'),ctx,scopeOk:()=>true,onFinished:async()=>true});
    await until(()=>x.host.querySelector('.ctl-last')?.textContent.includes('Actualisation terminée'),'rapport terminé absent');
    x.host.querySelector('[data-refresh-details]').click();
    eq(x.host.querySelector('.ctl-bar').getAttribute('aria-valuenow'),'100','succès vérifié complet');await capture('actualisation-terminee');
  } finally {refresh?.destroy();x.close();}
});

// Field report 2.0.7: a name absent from DNS is a definitive answer (Domenia.Core PresenceOutcomes), never « sonde en erreur ».
test('Actualisation : un nom absent du DNS termine le relevé ; une cause DNS transitoire le laisse incomplet et reprenable', async () => {
  const x=await fixtures();let refresh;
  const scope={label:'ADCC-Lab',dn:'OU=ADCC-Lab,DC=example,DC=local',subtree:true};
  const presence={id:'presence',label:'Relevé de présence (ping)',startedAt:null,finishedAt:null};
  const definitive={id:'dns-absent',mode:'presence',status:'success',resumable:false,scope,runs:[],label:'Présence relevée par ping : OU ADCC-Lab · 1 nom absent du DNS',
    stages:[{...presence,state:'done',detail:'0 poste en ligne sur 5 · 4 sans réponse · 1 nom absent du DNS'}]};
  const transient={...definitive,id:'dns-timeout',status:'partial',resumable:true,label:'Actualisation partielle : OU ADCC-Lab · 1 poste non vérifié (délai DNS dépassé)',
    stages:[{...presence,state:'partial',detail:'0 poste en ligne sur 5 · 4 sans réponse · 1 non vérifié (délai DNS dépassé)'}]};
  let state={running:false,last:definitive};
  const ctx=await context(async(op)=>op==='accueil.refresh.state'?state:{});
  const open=()=>createRefresh({actions:x.host.querySelector('.hero-actions'),status:x.host.querySelector('.hero-status'),ctx,scopeOk:()=>true,onFinished:async()=>true});
  try {
    x.host.innerHTML='<div class="hero"><div class="hero-actions"></div><div class="hero-status"></div></div>';
    refresh=open();
    await until(()=>x.host.querySelector('.ctl-last')?.textContent.includes('1 nom absent du DNS'),'compte rendu du nom absent du DNS absent');
    const last=x.host.querySelector('.ctl-last');
    ok(last.textContent.includes('Terminée'),'nom absent du DNS : relevé terminé');
    ok(!last.querySelector('[data-refresh-mode="resume"]'),'aucune reprise proposée pour une réponse définitive');
    x.host.querySelector('[data-refresh-details]').click();
    eq(x.host.querySelector('.ctl-stage[data-state="done"] .ctl-st span').textContent,'0 poste en ligne sur 5 · 4 sans réponse · 1 nom absent du DNS','étape terminée qui nomme la réponse du DNS');
    eq(x.host.querySelector('.ctl-bar').getAttribute('aria-valuenow'),'100','relevé complet');
    for(const word of ['Échec','Partielle','Incomplète','sonde en erreur'])ok(!x.host.querySelector('.hero-status').textContent.includes(word),`aucun « ${word} » pour un nom absent du DNS`);
    refresh.destroy();
    state={running:false,last:transient};
    refresh=open();
    await until(()=>x.host.querySelector('.ctl-last')?.textContent.includes('délai DNS dépassé'),'compte rendu de la cause transitoire absent');
    ok(x.host.querySelector('.ctl-last').textContent.includes('Partielle'),'cause transitoire : relevé partiel');
    ok(x.host.querySelector('.ctl-last-text').textContent.includes('1 poste non vérifié (délai DNS dépassé)'),'compte rendu lisible seul : le poste restant porte son nom');
    ok(x.host.querySelector('.ctl-last [data-refresh-mode="resume"]'),'reprise proposée pour la cause transitoire');
    const details=x.host.querySelector('[data-refresh-details]');if(details.getAttribute('aria-expanded')!=='true')details.click();
    const stage=x.host.querySelector('.ctl-stage[data-state="partial"]');
    ok(stage,'étape exécutée avec des postes à reprendre');
    ok(stage.textContent.includes('Incomplète')&&!stage.textContent.includes('Échec')&&!stage.textContent.includes('En attente'),'« Incomplète », ni « Échec » ni état inconnu');
    ok(stage.textContent.includes('1 non vérifié (délai DNS dépassé)'),'cause transitoire nommée');
    ok(!x.host.querySelector('.hero-status').textContent.includes('sonde en erreur'),'aucune « sonde en erreur »');
    ok(!x.host.querySelector('.ctl-run').hidden,'étapes de la tentative incomplète affichées');
    const widths=[];
    for(const width of [1280,1024,800]){
      x.width(width);await delay(60);widths.push({requested:width,effective:rect(x.host).width});
      const span=x.host.querySelector('.ctl-stage[data-state="partial"] .ctl-st span');inside(span,span.closest('.ctl-stage'),`détail de l’étape incomplète contenu dans sa carte à ${width} px`);
    }
    await capture('actualisation-incomplete',()=>({widths,stageRectangles:[...x.host.querySelectorAll('.ctl-stage')].map(rect)}));
  } finally {refresh?.destroy();x.close();}
});

test('Recette visuelle : icônes Accueil et dernières fiches stables sur 18 secondes, thèmes et largeur', async () => {
  const x=await fixtures();let homeDispose,ficheDispose;
  const session={...(await mockCall('session.info')),connection:{state:'connected'}};
  const ctx=await context(async(op,args)=>{if(op==='session.info')return session;if(op==='dashboard.summary')throw Object.assign(new Error('Lecture de test refusée, base valide conservée.'),{code:'source.unavailable'});if(op==='accueil.refresh.state')return {running:false,last:null};if(op==='fiche.recent')return [];return mockCall(op,args);});
  try {
    homeDispose=renderHome(x.host,ctx);await until(()=>x.host.querySelector('.error-card .art'),'erreur Accueil non rendue');await delay(900);
    const art=x.host.querySelector('.error-card .art');art.scrollIntoView({block:'center'});const title=x.host.querySelector('.error-card h2');const before=rect(art);
    ok(!overlap(before,rect(title)),'aucun chevauchement initial');await capture('accueil-erreur-debut-cycle');
    const fiche=document.createElement('section');fiche.dataset.page='fiche';x.host.append(fiche);ficheDispose=renderEmpty(fiche,ctx);await until(()=>fiche.querySelector('.fi-empty-art'),'fiche vide non rendue');await delay(900);
    const ficheArt=fiche.querySelector('.fi-empty-art');const ficheBefore=rect(ficheArt);const homeBefore=rect(art);
    for(let i=0;i<3;i++){await delay(6000);const a=rect(art),b=rect(ficheArt);ok(Math.abs(a.x-homeBefore.x)<1&&Math.abs(a.y-homeBefore.y)<1,'Accueil stable sur ancien cycle');ok(Math.abs(b.x-ficheBefore.x)<1&&Math.abs(b.y-ficheBefore.y)<1,'Fiche stable sur ancien cycle');}
    inside(ficheArt,fiche.querySelector('.fi-recent'),'icône dans dernières fiches');ok(!overlap(rect(art),rect(title)),'aucun chevauchement après 18 secondes');await capture('accueil-erreur-fin-cycle',{before:homeBefore,after:rect(art),observationMs:18000});
    for(const theme of ['dark','light','contrast'])for(const motion of ['rich','reduced','system']){document.documentElement.dataset.theme=theme;document.documentElement.dataset.motion=motion;x.width(theme==='contrast'?800:1024);await delay(80);inside(ficheArt,fiche.querySelector('.fi-recent'),'fiche contenue thèmes/mouvements');eq(getComputedStyle(ficheArt).animationName,'none','pas de mouvement fonctionnel');}
    fiche.scrollIntoView();await capture('fiche-sans-historique',{icon:rect(ficheArt)});
  } finally {homeDispose?.();ficheDispose?.();x.close();}
});


test('Recette Accueil : première lecture inconnue et réponse tardive de l’ancienne OU rejetée', async () => {
  const x=await fixtures();let dispose;let count=0;const old=deferred();
  let session={...(await mockCall('session.info')),connection:{state:'connected'},cache:{state:'empty',label:'Aucune lecture',lastReadAt:null,objects:0,complete:false}};
  const base=await mockCall('dashboard.summary');
  const noData={...base,store:{...base.store,lastReadAt:null,complete:false},widgets:Object.fromEntries(Object.entries(base.widgets).map(([key,w])=>[key,{...w,data:null,measuredAt:null,detail:'Première lecture nécessaire'}]))};
  const fresh=structuredClone(base);fresh.widgets.activeAccounts.data.value=222;
  const obsolete=structuredClone(base);obsolete.widgets.activeAccounts.data.value=111;
  const ctx=await context(async(op,args)=>{
    if(op==='session.info')return session;
    if(op==='dashboard.summary'){count++;return count===1?noData:count===2?old.promise:fresh;}
    if(op==='accueil.refresh.state')return {running:false,last:null};
    const value=await mockCall(op,args);
    if(op==='accueil.board')return {...value,scope:session.scope,directory:{status:'never',at:null,partial:false,text:'Première lecture de cette OU nécessaire'}};
    return value;
  });
  try {
    dispose=renderHome(x.host,ctx);
    await until(()=>x.host.textContent.includes('Première lecture nécessaire'),'état sans données absent');
    ok(!x.host.querySelector('[data-widget="activeAccounts"] [data-count="0"]'),'inconnu non converti en zéro');
    await capture('accueil-premiere-lecture-necessaire');
    await capture('accueil-indicateur-premiere-lecture',{},x.host.querySelector('[data-widget="activeAccounts"]'));
    window.dispatchEvent(new CustomEvent('domenia:refresh-home'));await until(()=>count===2,'relecture locale non démarrée');
    session={...session,scope:{...session.scope,dn:'OU=Autres,DC=example,DC=local',label:'Autres'}};
    window.dispatchEvent(new CustomEvent('domenia:session',{detail:session}));
    await until(()=>x.host.querySelector('[data-widget="activeAccounts"] [data-count="222"]'),'nouvelle vue absente');
    old.resolve(obsolete);await delay(80);
    ok(x.host.querySelector('[data-widget="activeAccounts"] [data-count="222"]'),'résultat de la nouvelle OU conservé');
    ok(!x.host.querySelector('[data-widget="activeAccounts"] [data-count="111"]'),'résultat tardif retiré');
    ok(x.host.querySelector('h1')?.textContent.includes('Autres'),'titre du nouveau périmètre');
  } finally {old.resolve(obsolete);dispose?.();x.close();}
});
