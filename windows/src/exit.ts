/** 先同步阻止新编辑，再保存和退出；保存失败才恢复交互，确认退出后保持锁定。 */
export class ExitGate {
  pending = false;
  constructor(private setBusy: (busy: boolean) => void) {}
  async request(save: () => Promise<void>, confirm: () => Promise<void>): Promise<void> {
    if (this.pending) return;
    this.pending = true;
    this.setBusy(true);
    try { await save(); await confirm(); }
    catch (error) { this.pending = false; this.setBusy(false); throw error; }
  }
}
