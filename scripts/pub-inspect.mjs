async function show(name) {
  try {
    const res = await fetch(`https://pub.flutter-io.cn/api/packages/${name}`);
    if (!res.ok) {
      console.log(`${name}: HTTP ${res.status}`);
      return;
    }
    const data = await res.json();
    const latest = data.latest;
    const pubspec = latest?.pubspec ?? {};
    console.log(`\n=== ${name} ${latest?.version} ===`);
    console.log('description:', String(pubspec.description ?? '').slice(0, 220));
    console.log('sdk:', pubspec.environment?.sdk, '| flutter:', pubspec.environment?.flutter);
    console.log('deps:', Object.keys(pubspec.dependencies ?? {}).join(', ').slice(0, 200));
    const versions = (data.versions ?? []).slice(-4).map((v) => v.version);
    console.log('recent versions:', versions.join(' / '));
  } catch (error) {
    console.log(`${name}: FAIL ${error.message}`);
  }
}

for (const name of [
  'sqlite3',
  'sqlite3_flutter_libs',
  'lucide_icons_flutter',
  'flutter_lucide',
  'material_symbols_icons',
  'window_manager',
  'file_picker',
  'share_plus',
]) {
  await show(name);
}
