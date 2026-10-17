import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: { testTimeout: 15000, hookTimeout: 20000, fileParallelism: false },
});
