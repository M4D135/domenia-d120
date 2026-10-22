// Paramètres › Connexion et périmètre (PAR-047, PAR-048, PAR-049): the account and rights of the session, the connection
// preferences of the workstation (never a password; nothing remembered in simulation) and the working OU, chosen in a tree
// read level by level (directory.ou.children), with the sections that follow it.
import {
  esc, glyph, card, row, facts, notes, sectionHead, toggle, button, paint, skeleton, errorBlock, reported, pill, NBSP, isOff,
} from './common.js';
import { reveal } from '../../ui.js';
import { openDrawer } from '../../kit/drawer.js';
import { createTree } from '../../kit/tree.js';
import { confirmDialog } from '../../kit/dialog.js';

const isRoot = (dn, root) => typeof dn === 'string' && typeof root === 'string' && dn.toLowerCase() === root.toLowerCase();

function pathOf(view) {
  return view.scope.path ?? view.scope.label ?? '—';
}

function markup(v) {
  const sim = v.simulated;
  const session = card({
    id: 'session', title: 'Session', sub: sim ? 'Annuaire fictif, aucune connexion' : 'Compte utilisé pour l’annuaire', iconName: 'shield', toneName: sim ? 'accent' : 'info',
    body: `<div class="pr-identity">
        <span class="pr-avatar" aria-hidden="true">${glyph('user')}</span>
        <div class="pr-identity-text"><b class="mono">${esc(v.account.login)}</b><span>${esc(v.account.displayName ?? 'Nom affiché non lu')}</span></div>
        ${pill(v.connection.state === 'connected' ? 'ok' : v.connection.state === 'simulated' ? 'accent' : 'off', v.connection.label, { icon: sim ? 'sparkles' : 'server' })}
      </div>
      ${facts([
        ['Domaine', v.domain?.dnsName ?? 'Non connecté', v.domain?.netbiosName ? `NetBIOS ${v.domain.netbiosName}` : ''],
        ['Contrôleur', v.controller?.dnsName ?? 'Non connecté', v.controller?.site ? `Site ${v.controller.site}` : ''],
        ['Mode de connexion', v.authentication.label],
        ['Droits estimés', v.rights.label, v.rights.detail],
        ['Écritures', v.readOnly ? 'Lecture seule' : 'Possibles, chacune planifiée et confirmée', v.readOnly ? 'Aucune écriture admise dans ce mode' : 'Plan, confirmation, reçu avant l’envoi, relecture'],
      ])}`,
  });
  const p = v.preferences;
  const prefs = card({
    id: 'prefs', title: 'Préférences de connexion', sub: 'Mémorisées sur ce poste, jamais de mot de passe', iconName: 'key',
    body: row({
      label: 'Se souvenir de mon identifiant', desc: 'Le prochain écran de connexion propose le dernier identifiant ; décocher l’oublie aussi.', setting: 'remember',
      control: toggle('remember', 'Se souvenir de mon identifiant', p.rememberLogin, { disabled: !p.editable, reason: p.reason ?? '' }),
    })
      + facts([
        ['Dernier identifiant', p.lastLogin ?? (p.editable ? 'Aucun' : 'Rien n’est mémorisé en simulation')],
        ['Compte du coffre Windows', p.vault ? `${p.vault.domain}\\${p.vault.user}` : 'Aucun', 'Le coffre Windows n’est jamais lu au démarrage ni en arrière-plan'],
      ])
      + `<div class="pr-actions">${button('forget', 'Oublier l’identifiant et le compte du coffre', 'trash', { disabled: !p.editable || (!p.lastLogin && !p.vault), reason: !p.editable ? (p.reason ?? '') : (!p.lastLogin && !p.vault ? 'Rien à oublier.' : '') })}</div>`
      + notes(p.rules),
  });
  const root = v.domain?.rootDn ?? null;
  const scope = v.scope;
  const scopeCard = card({
    id: 'scope', title: 'OU de travail', sub: 'Défaut de toutes les sections sans choix propre', iconName: 'folder', cls: 'pr-wide',
    body: `<div class="pr-scope" data-setting="scope">
        <div class="pr-scope-main">
          <span class="pr-scope-k">${scope.wholeDomain ? 'Tout le domaine' : 'OU choisie'}</span>
          <b class="pr-scope-name">${esc(scope.label ?? 'Aucune OU choisie')}</b>
          <span class="pr-scope-path">${esc(pathOf(v))}</span>
          <span class="pr-scope-chips">${pill(scope.subtree ? 'info' : 'off', scope.subtree ? 'Sous-OU comprises' : 'Cette OU seulement', { size: 'sm' })}${scope.isDefault ? pill('ok', 'OU par défaut', { size: 'sm', icon: 'check' }) : pill('accent', 'Choix mémorisé', { size: 'sm', icon: 'pin' })}${scope.wholeDomain ? pill('warn', 'Mesures de postes refusées', { size: 'sm', icon: 'alert' }) : ''}</span>
        </div>
        <div class="pr-scope-actions">
          ${button('choose', 'Choisir l’OU…', 'folder', { kind: 'primary', small: false, extra: ' aria-haspopup="dialog"' })}
          ${button('default', `Revenir à l’OU par défaut${scope.defaultLabel ? ` (${scope.defaultLabel})` : ''}`, 'undo', { disabled: scope.isDefault || !scope.defaultDn, reason: scope.isDefault ? 'L’OU par défaut est déjà l’OU de travail.' : '' })}
          ${button('domain', 'Tout le domaine', 'domain', { disabled: !root || scope.wholeDomain, reason: scope.wholeDomain ? 'Tout le domaine est déjà l’OU de travail.' : '' })}
        </div>
      </div>
      <h4 class="pr-h4">Sections qui suivent l’OU de travail</h4>
      <ul class="pr-follow">${v.sections.map((s, n) => `<li data-j="${n}"><span class="pr-follow-ico">${glyph(s.follows ? 'link' : 'pin')}</span><div><b>${esc(s.label)}</b><span>${esc(s.detail)}</span></div>${pill(s.follows ? 'ok' : 'warn', s.follows ? `Suit · ${s.scopeLabel}` : `OU propre · ${s.scopeLabel}`, { size: 'sm' })}</li>`).join('')}</ul>
      ${notes(v.safeguards)}`,
  });
  return `${sectionHead({ title: 'Connexion et périmètre', lead: 'Le compte de la session, ce que ce poste mémorise pour la connexion, et l’OU qui sert de défaut à chaque section.', icon: 'user', tone: 'info' })}
    <div class="pr-grid">${session}${prefs}${scopeCard}</div>`;
}

export function mount(host, sctx, { open } = {}) {
  let view = null;
  let alive = true;
  let drawer = null;
  host.innerHTML = `${sectionHead({ title: 'Connexion et périmètre', lead: 'Lecture de la session…', icon: 'user', tone: 'info' })}${skeleton(3)}`;

  async function load() {
    try {
      view = await sctx.call('settings.connection');
      if (!alive) return;
      host.innerHTML = markup(view);
      paint(host);
      reveal(host);
      if (open === 'ou') { open = null; openPicker(); }
    } catch (err) {
      if (!alive) return;
      console.error(err);
      host.innerHTML = `${sectionHead({ title: 'Connexion et périmètre', lead: 'Lecture impossible.', icon: 'user', tone: 'info' })}${errorBlock(err)}`;
    }
  }

  async function setScope(dn, subtree, label) {
    try {
      const session = await sctx.call('session.setScope', { dn, subtree });
      sctx.ctx.showConnection?.(session);
      window.dispatchEvent(new CustomEvent('domenia:scope-changed', { detail: { scope: session.scope ?? null } }));
      sctx.toast(`OU de travail : ${session.scope?.label ?? label}${session.scope?.subtree ? ' et ses sous-OU' : ' seule'}. Mémorisée pour ce domaine.`, { tone: 'ok' });
      await load();
      host.querySelector('[data-card="scope"]')?.classList.add('pr-changed');
    } catch (err) {
      sctx.toast(reported(err), { tone: 'alert' });
    }
  }

  function openPicker() {
    if (!view) return;
    const root = view.domain?.rootDn;
    const body = document.createElement('div');
    body.className = 'pr-ou-picker';
    body.innerHTML = `<p class="pr-ou-lead">Choisissez l’OU qui sert de défaut aux sections. L’arbre se lit niveau par niveau, à l’ouverture d’une branche ; rien d’autre n’est lu.</p>
      <div class="pr-ou-tree"></div>
      <label class="pr-ou-sub"><input type="checkbox" class="switch" role="switch" data-sub${view.scope.subtree ? ' checked' : ''}><span>Sous-OU comprises</span></label>
      <p class="pr-ou-pick" data-pick aria-live="polite">Aucune OU sélectionnée.</p>`;
    let picked = null;
    const toNodes = (list) => list.map((o) => ({
      id: o.dn, label: o.name, leaf: !o.hasChildren, icon: 'ou',
      hint: `${o.counts.computers ? `${o.counts.computers} postes` : ''}${o.counts.computers && o.counts.users ? ' · ' : ''}${o.counts.users ? `${o.counts.users} comptes` : ''}`,
      data: o,
    }));
    drawer = openDrawer({
      title: 'Choisir l’OU de travail', subtitle: view.domain?.dnsName ?? '', icon: 'folder', key: 'parametres.ou', width: 520, minWidth: 380, maxWidth: 900,
      body,
      actions: [
        { id: 'cancel', label: 'Annuler', run: (d) => d.close() },
        { id: 'apply', label: 'Appliquer', primary: true, run: (d) => {
          if (!picked) { sctx.toast('Sélectionnez une OU dans l’arbre.', { tone: 'warn' }); return; }
          const subtree = body.querySelector('[data-sub]').checked;
          d.close();
          setScope(picked.dn, subtree, picked.name);
        } },
      ],
      onClose: () => { tree?.destroy(); drawer = null; },
    });
    let tree = null;
    const start = () => {
      const treeHost = body.querySelector('.pr-ou-tree');
      if (!treeHost?.isConnected) { setTimeout(start, 80); return; }
      tree = createTree(treeHost, {
        label: 'Unités d’organisation',
        height: '420px',
        searchPlaceholder: 'Filtrer les branches déjà lues…',
        roots: () => sctx.call('directory.ou.children', { dn: null }).then((r) => {
          // The tree inserts the roots after this promise: the current OU is revealed on the next turn.
          setTimeout(revealCurrent, 0);
          return toNodes(r.children);
        }),
        load: (node) => sctx.call('directory.ou.children', { dn: node.id }).then((r) => toNodes(r.children)),
        onSelect: (node) => {
          picked = node.data;
          body.querySelector('[data-pick]').innerHTML = `${glyph('check')}<span>${esc(picked.path)}</span>`;
        },
        onActivate: (node) => { picked = node.data; drawer?.foot?.querySelector('[data-id="apply"]')?.click(); },
      });
    };
    // Opens the path of the current OU (each level read once) and selects it, so « Appliquer » keeps it as is.
    const revealCurrent = () => {
      if (!tree || !view.scope.dn || isRoot(view.scope.dn, root)) return;
      const chain = [];
      let dn = view.scope.dn;
      while (dn && !isRoot(dn, root)) {
        chain.unshift(dn);
        const at = dn.search(/(?<!\\),/);
        dn = at > 0 ? dn.slice(at + 1) : '';
      }
      tree.reveal(chain).then((ok) => {
        const node = ok ? tree?.getSelected() : null;
        if (!node?.data) return;
        picked = node.data;
        body.querySelector('[data-pick]').innerHTML = `${glyph('check')}<span>${esc(picked.path)}</span><span class="pr-sub">OU actuelle</span>`;
      }).catch((err) => console.error(err));
    };
    start();
  }

  const onClick = async (e) => {
    const act = e.target instanceof Element ? e.target.closest('[data-act]') : null;
    if (isOff(act) || !view) return;
    const name = act.dataset.act;
    if (name === 'retry') load();
    else if (name === 'choose') openPicker();
    else if (name === 'default' && view.scope.defaultDn) setScope(view.scope.defaultDn, true, view.scope.defaultLabel);
    else if (name === 'domain') {
      const ok = await confirmDialog({
        title: 'Prendre tout le domaine ?',
        message: `Tout le domaine ${view.domain?.dnsName ?? ''} devient l’OU de travail. Les comptes restent lus sur le domaine ; les mesures de postes restent refusées tant qu’aucune OU n’est choisie (jamais tout le domaine).`,
        confirmLabel: 'Prendre tout le domaine',
      });
      if (ok && view.domain?.rootDn) setScope(view.domain.rootDn, true, view.domain.dnsName);
    } else if (name === 'forget') {
      try {
        view = await sctx.call('settings.connection.forget');
        sctx.toast('Dernier identifiant et compte du coffre oubliés. Le coffre Windows lui-même n’est pas modifié.', { tone: 'ok' });
        host.innerHTML = markup(view);
        paint(host);
        reveal(host);
      } catch (err) {
        sctx.toast(reported(err), { tone: 'warn' });
      }
    }
  };
  const onChange = async (e) => {
    const input = e.target instanceof HTMLInputElement && e.target.matches('[data-toggle="remember"]') ? e.target : null;
    if (!input) return;
    input.disabled = true;
    try {
      view = await sctx.call('settings.connection.set', { rememberLogin: input.checked });
      sctx.toast(input.checked ? 'Identifiant mémorisé à la prochaine connexion (jamais le mot de passe).' : `Identifiant oublié${NBSP}: rien n’est plus proposé.`, { tone: 'ok' });
    } catch (err) {
      input.checked = !input.checked;
      sctx.toast(reported(err), { tone: 'warn' });
    } finally {
      input.disabled = !view?.preferences?.editable;
    }
  };
  host.addEventListener('click', onClick);
  host.addEventListener('change', onChange);
  load();

  return {
    destroy() {
      alive = false;
      drawer?.close();
      host.removeEventListener('click', onClick);
      host.removeEventListener('change', onChange);
    },
  };
}
