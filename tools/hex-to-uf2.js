#!/usr/bin/env node
// Minimal Intel HEX -> UF2 converter for the Adafruit nRF52840 bootloader.
// Uses the family ID specified by the installed Seeeduino nRF52 platform.
const fs = require('node:fs');

const [input, output] = process.argv.slice(2);
if (!input || !output) {
  console.error('Usage: node hex-to-uf2.js input.hex output.uf2');
  process.exit(2);
}

const MAGIC0 = 0x0a324655;
const MAGIC1 = 0x9e5d5157;
const MAGIC_END = 0x0ab16f30;
const FAMILY_ID = 0xada52840;
const blocks = new Map();
let upper = 0;

for (const rawLine of fs.readFileSync(input, 'utf8').split(/\r?\n/)) {
  const line = rawLine.trim();
  if (!line) continue;
  if (line[0] !== ':') throw new Error(`Invalid HEX line: ${line}`);
  const bytes = Buffer.from(line.slice(1), 'hex');
  const length = bytes[0];
  if (bytes.length !== length + 5) throw new Error('Invalid Intel HEX record length');
  if ((bytes.reduce((sum, value) => sum + value, 0) & 0xff) !== 0) throw new Error('Intel HEX checksum mismatch');
  const address16 = (bytes[1] << 8) | bytes[2];
  const type = bytes[3];

  if (type === 0x01) break;
  if (type === 0x04) { upper = ((bytes[4] << 8) | bytes[5]) << 16; continue; }
  if (type === 0x02) { upper = ((bytes[4] << 8) | bytes[5]) << 4; continue; }
  if (type !== 0x00) continue;

  for (let index = 0; index < length; index++) {
    const address = upper + address16 + index;
    const base = address & ~0xff;
    if (!blocks.has(base)) blocks.set(base, Buffer.alloc(256));
    blocks.get(base)[address & 0xff] = bytes[4 + index];
  }
}

const ordered = [...blocks.entries()].sort((a, b) => a[0] - b[0]);
const outputBlocks = ordered.map(([address, payload], index) => {
  const block = Buffer.alloc(512);
  block.writeUInt32LE(MAGIC0, 0);
  block.writeUInt32LE(MAGIC1, 4);
  block.writeUInt32LE(0x2000, 8); // family ID is present
  block.writeUInt32LE(address >>> 0, 12);
  block.writeUInt32LE(256, 16);
  block.writeUInt32LE(index, 20);
  block.writeUInt32LE(ordered.length, 24);
  block.writeUInt32LE(FAMILY_ID, 28);
  payload.copy(block, 32);
  block.writeUInt32LE(MAGIC_END, 508);
  return block;
});

if (!outputBlocks.length) throw new Error('No data records found in HEX');
fs.writeFileSync(output, Buffer.concat(outputBlocks));
console.log(`Created ${output}: ${outputBlocks.length} blocks, ${outputBlocks.length * 512} bytes`);
