const url = 'https://aka.ms/vs/17/release/vs_BuildTools.exe';
const out = 'D:\\vs_buildtools.exe';

const res = await fetch(url, { redirect: 'follow' });
if (!res.ok) {
  console.error('HTTP', res.status);
  process.exit(1);
}
const buffer = Buffer.from(await res.arrayBuffer());
const { writeFileSync, statSync } = await import('node:fs');
writeFileSync(out, buffer);
console.log(`saved ${out} ${(statSync(out).size / 1024).toFixed(0)} KB`);
