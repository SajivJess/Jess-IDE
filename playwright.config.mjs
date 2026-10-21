import { defineConfig, devices } from '@playwright/test';

export default defineConfig({
  testDir: './tests/browser', testMatch: '**/*.spec.mjs',
  fullyParallel: false, workers: 1, timeout: 45000,
  globalTeardown: './tests/browser/teardown.mjs',
  expect: { timeout: 15000 }, reporter: 'list', outputDir: '.local/browser-results',
  use: { baseURL: 'http://localhost:4173', trace: 'retain-on-failure', screenshot: 'only-on-failure' },
  projects: [
    { name: 'phone', use: { ...devices['Pixel 7'], defaultBrowserType: 'chromium' } },
    { name: 'desktop', use: { viewport: { width: 1440, height: 1000 }, browserName: 'chromium' } },
  ],
  webServer: {
    command: 'node --env-file=.env tests/browser/server.mjs',
    url: 'http://localhost:4173', reuseExistingServer: false, timeout: 30000,
    gracefulShutdown: { signal: 'SIGTERM', timeout: 10000 },
  },
});
