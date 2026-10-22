import { expandCalendars } from './calendar';
import type { CalendarRequest, CalendarResponse } from './calendar-client';

// 所有不可信 ICS 解析、时区准备和同步迭代均留在此线程。
self.onmessage = (message: MessageEvent<CalendarRequest>): void => {
  const { id, sources, from, to } = message.data;
  let response: CalendarResponse;
  try { response = { id, result: expandCalendars(sources, new Date(from), new Date(to)) }; }
  catch (error) { response = { id, error: error instanceof Error ? error.message : String(error) }; }
  self.postMessage(response);
};
