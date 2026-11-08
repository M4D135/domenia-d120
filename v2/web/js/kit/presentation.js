// Presentation only: no call to the engine, no permission or stored layout change.
import { createTabs } from './tabs.js';

export const expertView = ctx => ctx?.presentation?.get?.().expert ?? ctx?.expert === true;
export function watchPresentation(ctx, change) {
  return ctx?.presentation?.on?.(change) ?? (() => {});
}
export function bindPresentation(root, ctx) {
  const paint = () => { root.dataset.profile = expertView(ctx) ? 'expert' : 'essentiel'; };
  paint();
  return watchPresentation(ctx, paint);
}
export function presentationTabs(host, ctx, options) {
  const entries = () => ctx?.presentation?.get?.().guiPolicy ?? [];
  const mode = tab => entries().find(e => e.valid && String(e.element).toLowerCase() === String(tab.gui ?? '').toLowerCase())?.policy;
  const tabs = createTabs(host, { ...options, tabs: options.tabs.map(tab => ({ ...tab,
    hidden: () => (tab.expert === true && !expertView(ctx)) || mode(tab) === 'Hidden' || tab.hidden === true,
    disabled: () => tab.disabled === true || mode(tab) === 'Disabled',
  })) });
  const off = watchPresentation(ctx, () => tabs.refresh());
  return { ...tabs, destroy() { off(); tabs.destroy(); } };
}
