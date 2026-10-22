export type PanelShortcut = 'overview' | 'media' | 'calendar' | 'notes' | 'files' | 'new-note' | 'save' | 'escape';
export function panelShortcut(event: { key: string; ctrlKey: boolean; metaKey: boolean; altKey: boolean; shiftKey: boolean; isComposing: boolean; repeat?: boolean }, expanded: boolean): PanelShortcut | null {
  if (!expanded || event.repeat || event.isComposing || event.altKey || event.shiftKey) return null;
  if (event.key === 'Escape' && !event.ctrlKey && !event.metaKey) return 'escape';
  if (!event.ctrlKey && !event.metaKey) return null;
  const shortcuts: Record<string, PanelShortcut> = { '0': 'overview', '1': 'media', '2': 'calendar', '3': 'notes', '4': 'files', n: 'new-note', s: 'save' };
  return shortcuts[event.key.toLowerCase()] || null;
}
