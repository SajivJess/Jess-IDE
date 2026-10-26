#!/usr/bin/env node
/**
 * check-meta-models.mjs
 *
 * Calls GET /v1/models on the configured Meta API base URL and prints
 * every available model ID. Run this BEFORE setting META_MODEL_ID in .env.
 *
 * Usage (from repo root, after adding MODEL_API_KEY to root .env):
 *   node --env-file=.env scripts/check-meta-models.mjs
 */

import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);

const apiKey = process.env.MODEL_API_KEY;
const baseUrl = process.env.META_MODEL_BASE_URL ?? 'https://api.meta.ai/v1';

if (!apiKey || apiKey.length < 8) {
  console.error('\n❌  MODEL_API_KEY is not set or is too short.');
  console.error('    Add it to your root .env file (not backend/.env).\n');
  process.exit(1);
}

console.log(`\n🔍  Checking models at ${baseUrl} ...\n`);

try {
  const OpenAI = require('openai');
  const client = new OpenAI.default({ apiKey, baseURL: baseUrl });
  const list = await client.models.list();

  if (!list.data?.length) {
    console.log('⚠️   The API responded but returned an empty model list.');
    console.log('    Check that your account has access and credits are active.\n');
    process.exit(0);
  }

  console.log('✅  Available models:\n');
  for (const model of list.data) {
    console.log(`   • ${model.id}`);
  }

  console.log('\n📝  Set META_MODEL_ID=<model-id> in your root .env and set AGENT_PROVIDER=meta to enable the real agent.\n');
} catch (err) {
  const msg = err?.message ?? String(err);
  const status = err?.status ?? err?.statusCode;

  if (status === 401) {
    console.error('\n❌  Authentication failed (401). Check that MODEL_API_KEY is correct and active.\n');
  } else if (status === 403) {
    console.error('\n❌  Access denied (403). Your key may not have models:list permission.\n');
  } else if (status === 429) {
    console.error('\n❌  Rate limited (429). Wait a moment and try again.\n');
  } else if (msg.includes('ECONNREFUSED') || msg.includes('ENOTFOUND')) {
    console.error(`\n❌  Cannot reach ${baseUrl}. Check your internet connection.\n`);
  } else {
    console.error(`\n❌  Error: ${msg}\n`);
  }
  process.exit(1);
}
