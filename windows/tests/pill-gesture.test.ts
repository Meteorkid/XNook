import { test } from 'node:test';
import assert from 'node:assert/strict';
import { PillGesture } from '../src/pill-gesture';

test('收起药丸水平超过4px才开始拖动，拖动后只吞一次click', () => {
  const gesture = new PillGesture();
  assert.equal(gesture.begin(1, 100, 20), true);
  assert.equal(gesture.move(1, 104, 20), 'none');
  assert.equal(gesture.move(1, 105, 21), 'dragBegin');
  assert.equal(gesture.dragging, true);
  assert.equal(gesture.move(1, 120, 22), 'dragUpdate');
  assert.equal(gesture.end(1), 'dragEnd');
  assert.equal(gesture.active, false);
  assert.equal(gesture.consumeClick(), true);
  assert.equal(gesture.consumeClick(), false);
});

test('向下超过15px只展开一次，垂直方向锁不会又拖窗口', () => {
  const gesture = new PillGesture(); gesture.begin(1, 0, 0);
  assert.equal(gesture.move(1, 1, 5), 'none');
  assert.equal(gesture.move(1, 100, 10), 'none');
  assert.equal(gesture.move(1, 100, 15), 'none');
  assert.equal(gesture.move(1, 100, 16), 'expand');
  assert.equal(gesture.move(1, 100, 30), 'none');
  assert.equal(gesture.end(1), 'none');
  assert.equal(gesture.consumeClick(), true);
});

test('水平方向一旦锁定，之后向下大幅移动不会展开', () => {
  const gesture = new PillGesture(); gesture.begin(1, 0, 0);
  assert.equal(gesture.move(1, -5, 1), 'dragBegin');
  assert.equal(gesture.move(1, -6, 100), 'dragUpdate');
  assert.equal(gesture.end(1), 'dragEnd');
});

test('向上不展开；斜向等距选择垂直且新按下清理上次click抑制', () => {
  const gesture = new PillGesture(); gesture.begin(1, 0, 0);
  assert.equal(gesture.move(1, 5, -5), 'none');
  assert.equal(gesture.move(1, 30, -20), 'none');
  gesture.end(1);
  gesture.begin(2, 0, 0); gesture.end(2);
  assert.equal(gesture.consumeClick(), false);
});

test('取消和失去capture结束拖动，普通点击与排除目标保持不动', () => {
  const gesture = new PillGesture();
  assert.equal(gesture.begin(1, 10, 10, false), false);
  assert.equal(gesture.move(1, 100, 100), 'none');
  assert.equal(gesture.begin(1, 10, 10), true);
  assert.equal(gesture.begin(2, 10, 10), false);
  assert.equal(gesture.move(2, 100, 100), 'none');
  assert.equal(gesture.cancel(2), 'none');
  assert.equal(gesture.active, true);
  assert.equal(gesture.move(1, 20, 10), 'dragBegin');
  assert.equal(gesture.cancel(1), 'dragEnd');
  assert.equal(gesture.cancel(), 'none');
  assert.equal(gesture.begin(2, 10, 10, false), false);
  assert.equal(gesture.consumeClick(), false);
  gesture.begin(2, 10, 10);
  assert.equal(gesture.end(2), 'none');
  assert.equal(gesture.consumeClick(), false);
  assert.equal(gesture.begin(3, NaN, 10), false);
});
