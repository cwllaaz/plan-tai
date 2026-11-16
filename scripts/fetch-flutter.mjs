import { createWriteStream, existsSync, mkdirSync, statSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import path from 'node:path';

const URL_ZIP = 'https://storage.flutter-io.cn/flutter_infra_release/releases/stable/windows/flutter_windows_3.50.0-stable.zip';
const OUT = process.env.FLUTTER_ZIP_OUT || 'D:\\flutter-sdk.zip';

const outDir = path.dirname(OUT);
if (!existsSync(outDir)) mkdirSync(outDir, { recursive: true });

const ctrl = new AbortController();
const res = await fetch(URL_ZIP, { signal: ctrl.signal, redirect: 'follow' });
if (!res.ok) {
  console.error('HTTP', res.status);
  process.exit(1);
}
const total = Number(res.headers.get('content-length') || 0);
console.log(`size = ${(total / 1024 / 1024).toFixed(1)} MB`);

const hash = createHash('sha256');
let received = 0;
let lastPrint = 0;
const started = Date.now();

const body = Readable.fromWeb(res.body);
body.on('data', (chunk) => {
  received += chunk.length;
  hash.update(chunk);
  const now = Date.now();
  if (now - lastPrint > 3000) {
    lastPrint = now;
    const mbps = received / 1024 / 1024 / ((now - started) / 1000);
    const pct = total ? ((received / total) * 100).toFixed(1) : '?';
    console.log(`${pct}%  ${(received / 1024 / 1024).toFixed(0)}MB  ${mbps.toFixed(1)} MB/s`);
  }
});

await pipeline(body, createWriteStream(OUT));
const digest = hash.digest('hex');
console.log(`done bytes=${received} sha256=${digest}`);
console.log(`file=${OUT} ${(statSync(OUT).size / 1024 / 1024).toFixed(1)} MB`);
