const targets = [
  'https://storage.flutter-io.cn/flutter_infra_release/releases/releases_windows.json',
  'https://storage.googleapis.com/flutter_infra_release/releases/releases_windows.json',
  'https://pub.flutter-io.cn/api/packages/drift',
  'https://pub.dev/api/packages/drift',
];

for (const url of targets) {
  const started = Date.now();
  try {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), 20000);
    const res = await fetch(url, { signal: ctrl.signal, redirect: 'follow' });
    clearTimeout(timer);
    const text = await res.text();
    console.log(`OK   ${res.status}  ${text.length}B  ${Date.now() - started}ms  ${url}`);
    if (url.includes('releases_windows')) {
      const data = JSON.parse(text);
      const stable = data.current_release?.stable;
      const rel = data.releases.find((r) => r.hash === stable);
      console.log('     stable =', rel?.version, '| archive =', rel?.archive);
      console.log('     sha256 =', rel?.sha256?.slice(0, 16) + '...');
    }
    if (url.includes('/api/packages/')) {
      const data = JSON.parse(text);
      console.log('     latest =', data.latest?.version);
    }
  } catch (error) {
    console.log(`FAIL ${String(error.message).slice(0, 80)}  ${url}`);
  }
}
