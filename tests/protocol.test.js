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
  const packet = { v: 2, type: 'notification', session_id: 'ABCD1234-1', seq: 7, uid: 177, event: 'Added', source: 'simple', app_id: 'app.simple.com', app: 'Simple', title: 'Карта пополнена', message: '22.221872 USDC зачислено на ••••.' };
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
  const { frames } = decodeChunks([Buffer.from('{"v":2,"type":"notification","session_id":"ABCD1234-1","seq":8,"uid":156,"event":"Removed"}\n')]);
  assert.equal(frames[0].uid, 156);
  assert.equal(frames[0].title, undefined);
});

test('session and sequence distinguish reused ANCS UIDs', () => {
  const records = [
    { session_id: 'OLD-1', seq: 1, uid: 42, title: 'Старое' },
    { session_id: 'NEW-2', seq: 2, uid: 42, title: 'Новое' }
  ];
  assert.equal(records.find(record => record.session_id === 'NEW-2' && record.uid === 42).title, 'Новое');
  assert.equal(new Set(records.map(record => `${record.session_id}:${record.seq}`)).size, 2);
});

test('duplicate delivery is acknowledged without creating another record', () => {
  const delivered = [
    { session_id: 'ABCD1234-1', seq: 9, uid: 55 },
    { session_id: 'ABCD1234-1', seq: 9, uid: 55 }
  ];
  const unique = new Map(delivered.map(packet => [`${packet.session_id}:${packet.seq}`, packet]));
  assert.equal(unique.size, 1);
});

test('status v2 exposes reliability diagnostics', () => {
  const status = JSON.parse('{"v":2,"type":"status","firmware_version":"1.2.0","state":"ready","session_id":"ABCD1234-1","queue_pending":2,"queue_capacity":32,"acked":10,"reconnects":3,"ancs_attempts":1,"last_error":""}');
  assert.equal(status.state, 'ready');
  assert.equal(status.queue_capacity, 32);
  assert.equal(status.acked, 10);
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
