import { readFileSync } from 'node:fs';
import { deflateRawSync } from 'node:zlib';
import vm from 'node:vm';
import assert from 'node:assert/strict';
import { test } from 'node:test';

const html = readFileSync(new URL('../web/sign/index.html', import.meta.url), 'utf8');
const source = html.match(/<script>([\s\S]*?)<\/script>/)[1]
  .replace('(async () => {', 'globalThis.render = (async () => {');
const payload = Buffer.from(deflateRawSync(JSON.stringify({
  title: 'QA only', from: 'Alex Example', me: 1,
  recipients: [{ party: 1, partyRole: 'Borrower' }],
}))).toString('base64url');
const fragment = `id=11111111-1111-1111-1111-111111111111&d=${payload}`;

async function render(hash, language = 'en', store = null) {
  const nodes = Object.fromEntries(['ok', 'bad', 'gone', 'get', 'open', 'web', 'headline', 'role', 'title', 'why', 'art'].map(id => [id, {
    hidden: ['ok', 'bad', 'gone', 'web'].includes(id), textContent: '',
    addEventListener() {},
  }]));
  const context = vm.createContext({
    navigator: { languages: [language] }, location: { hash: `#${hash}` },
    document: {
      documentElement: {},
      getElementById: id => nodes[id],
      querySelectorAll: () => [],
      querySelector: () => nodes.why,
    },
    window: { addEventListener() {} },
    URLSearchParams, Blob, DecompressionStream, Response, Uint8Array, atob,
    fetch: async () => ({ ok: false }),
  });
  vm.runInContext(store ? source.replace('const APP_STORE_URL = null;', `const APP_STORE_URL = ${JSON.stringify(store)};`) : source, context);
  await context.render;
  return nodes;
}

test('prelaunch invites offer browser signing with no generic download link', async () => {
  for (const language of ['en', 'zh-TW', 'zh-CN', 'ja', 'ko', 'es', 'fr', 'de']) {
    const n = await render(`${fragment}&ds=https%3A%2F%2Fexample.com%2Fqa-sign`, language);
    assert.equal(n.ok.hidden, false);
    assert.equal(n.get.href, 'https://example.com/qa-sign');
    assert.ok(n.get.textContent.length > 0);
    assert.equal(n.web.hidden, true);
    assert.ok(n.open.href.startsWith('handshake://sign/'));
  }
});

test('without a browser link, explain availability and keep installed-app access', async () => {
  const n = await render(fragment);
  assert.equal(n.get.hidden, true);
  assert.match(n.why.textContent, /isn't available to download yet/);
  assert.equal(n.open.hidden, false);
});

test('invalid browser destinations are not offered', async () => {
  const n = await render(`${fragment}&ds=javascript%3Aalert(1)`);
  assert.equal(n.get.hidden, true);
  assert.equal(n.web.hidden, true);
});

test('a future real App Store listing restores the install action and browser alternative', async () => {
  const n = await render(`${fragment}&ds=https%3A%2F%2Fexample.com%2Fqa-sign`, 'en', 'https://apps.apple.com/app/id123456');
  assert.equal(n.get.href, 'https://apps.apple.com/app/id123456');
  assert.equal(n.web.hidden, false);
  assert.equal(n.web.href, 'https://example.com/qa-sign');
});

test('malformed and unavailable links show their respective error states', async () => {
  assert.equal((await render('id=bad&d=bad')).bad.hidden, false);
  assert.equal((await render('s=AAAAAAAAAAAA.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA')).gone.hidden, false);
});
