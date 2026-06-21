const test = require('node:test');
const assert = require('node:assert/strict');

function decodeChunks(chunks) {
  let buffer = Buffer.alloc(0);
  const frames = [];
  for (const chunk of chunks) {
    buffer = Buffer.concat([buffer, chunk]);
    let newline;
    while ((newline = buffer.indexOf(0x0a)) >= 0) {
      const line = buffer.subarray(0, newline);
      buffer = buffer.subarray(newline + 1);
      if (line.length) frames.push(JSON.parse(line.toString('utf8')));
    }
  }
  return { frames, buffer };
}

function classify(source, appID = '', app = '') {
  if (['okx', 'binance', 'bybit', 'simple', 'other'].includes(source)) return source;
  const value = `${appID} ${app}`.toLowerCase();
  if (value.includes('simple') || value.includes('app.simple.com')) return 'simple';
  if (value.includes('binance')) return 'binance';
  if (value.includes('bybit')) return 'bybit';
  if (value.includes('okx') || value.includes('okex')) return 'okx';
  return 'other';
}

test('decodes fragmented UTF-8 JSON Lines', () => {
  const packet = { v: 1, type: 'notification', uid: 177, event: 'Added', source: 'simple', app_id: 'app.simple.com', app: 'Simple', title: 'Карта пополнена', message: '22.221872 USDC зачислено на ••••.' };
  const payload = Buffer.from(`${JSON.stringify(packet)}\n`);
  const { frames, buffer } = decodeChunks([payload.subarray(0, 3), payload.subarray(3, 31), payload.subarray(31, 70), payload.subarray(70)]);
  assert.deepEqual(frames, [packet]);
  assert.equal(buffer.length, 0);
});

test('keeps an incomplete tail after complete frames', () => {
  const first = Buffer.from('{"v":1,"type":"status","event":"bridge_ready"}\n');
  const second = Buffer.from('{"v":1,"type":"notification","uid":8');
  const { frames, buffer } = decodeChunks([Buffer.concat([first, second])]);
  assert.equal(frames[0].type, 'status');
  assert.deepEqual(buffer, second);
});

test('Removed packet needs only a UID', () => {
  const { frames } = decodeChunks([Buffer.from('{"v":1,"type":"notification","uid":156,"event":"Removed"}\n')]);
  assert.equal(frames[0].uid, 156);
  assert.equal(frames[0].title, undefined);
});

test('classifies known and unknown applications', () => {
  assert.equal(classify(undefined, 'app.simple.com'), 'simple');
  assert.equal(classify(undefined, 'com.okex.OKEx', 'OKX'), 'okx');
  assert.equal(classify(undefined, 'com.binance.dev', 'Binance'), 'binance');
  assert.equal(classify(undefined, 'com.bybit.app', 'Bybit'), 'bybit');
  assert.equal(classify(undefined, 'com.apple.MobileSMS', 'Сообщения'), 'other');
});

test('rejects malformed JSON', () => {
  assert.throws(() => decodeChunks([Buffer.from('{"type":broken}\n')]), SyntaxError);
});
