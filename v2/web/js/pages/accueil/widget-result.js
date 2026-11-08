// A completed bridge call is not evidence that a widget contains a usable measurement.
export function widgetRefreshFeedback(widget) {
  const title = widget?.title || 'Indicateur';
  if (widget?.data == null || !widget.measuredAt) {
    return { result: 'failed', tone: 'warn', text: `${title} : aucune mesure disponible. ${widget?.detail || 'Consultez le détail de la tuile.'}` };
  }
  if (widget.stale || widget.tone === 'off') {
    return { result: 'failed', tone: 'warn', text: `${title} : mesure incomplète ou ancienne. ${widget.detail || ''}` };
  }
  return { result: 'ok', tone: 'ok', text: `${title} : mesure actualisée.` };
}
