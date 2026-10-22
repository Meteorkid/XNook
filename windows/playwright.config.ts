import { defineConfig } from '@playwright/test';

export default defineConfig({
  testDir: './e2e',
  fullyParallel: false,
  workers: 1,
  use: {
    baseURL: 'http://127.0.0.1:1421',
    viewport: { width: 1000, height: 850 },
    browserName: 'chromium',
    channel: 'chrome',
    headless: true,
    reducedMotion: 'reduce',
    locale: 'zh-CN',
    timezoneId: 'Asia/Shanghai',
  },
  webServer: {
    command: 'npm run dev',
    url: 'http://127.0.0.1:1421',
    reuseExistingServer: true,
    timeout: 30_000,
  },
});
