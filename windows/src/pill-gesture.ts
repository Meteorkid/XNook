export type PillGestureAction = 'none' | 'dragBegin' | 'dragUpdate' | 'dragEnd' | 'expand';
type Phase = 'pending' | 'horizontal' | 'vertical' | 'expanded';
interface Pointer { id: number; x: number; y: number; phase: Phase }

/** 收起药丸使用单一方向锁；原生拖动和展开由调用方执行。 */
export class PillGesture {
  private pointer: Pointer | null = null;
  private suppressClick = false;

  get active(): boolean { return this.pointer !== null; }
  get dragging(): boolean { return this.pointer?.phase === 'horizontal'; }

  begin(pointerId: number, x: number, y: number, eligible = true): boolean {
    if (this.pointer) return false;
    // cancel 未必产生 click；新按下（包括封面按钮）不能继承上次的抑制。
    this.suppressClick = false;
    if (!eligible || ![pointerId, x, y].every(Number.isFinite)) return false;
    this.pointer = { id: pointerId, x, y, phase: 'pending' };
    return true;
  }

  move(pointerId: number, x: number, y: number): PillGestureAction {
    const pointer = this.pointer;
    if (!pointer || pointer.id !== pointerId || ![x, y].every(Number.isFinite)) return 'none';
    const dx = x - pointer.x, dy = y - pointer.y;
    if (pointer.phase === 'pending') {
      if (Math.abs(dx) > 4 && Math.abs(dx) > Math.abs(dy)) {
        pointer.phase = 'horizontal'; this.suppressClick = true; return 'dragBegin';
      }
      if (Math.abs(dy) > 4 && Math.abs(dy) >= Math.abs(dx)) {
        pointer.phase = 'vertical'; this.suppressClick = true;
      }
    }
    if (pointer.phase === 'horizontal') return 'dragUpdate';
    if (pointer.phase === 'vertical' && dy > 15) { pointer.phase = 'expanded'; return 'expand'; }
    return 'none';
  }

  end(pointerId: number): PillGestureAction {
    if (this.pointer?.id !== pointerId) return 'none';
    return this.cancel();
  }

  cancel(pointerId?: number): PillGestureAction {
    if (!this.pointer || (pointerId !== undefined && this.pointer.id !== pointerId)) return 'none';
    const result = this.dragging ? 'dragEnd' : 'none';
    this.pointer = null;
    return result;
  }

  consumeClick(): boolean {
    const suppressed = this.suppressClick;
    this.suppressClick = false;
    return suppressed;
  }
}
