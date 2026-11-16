const packages = [
  'sqlite3',
  'sqlite3_flutter_libs',
  'window_manager',
  'lucide_icons',
  'path_provider',
  'path',
  'uuid',
  'collection',
  'intl',
];

for (const name of packages) {
  try {
    const res = await fetch(`https://pub.flutter-io.cn/api/packages/${name}`);
    const data = await res.json();
    const latest = data.latest;
    const sdk = latest?.pubspec?.environment ?? {};
    console.log(`${name.padEnd(22)} ${String(latest?.version).padEnd(10)} sdk=${sdk['sdk'] ?? '?'}`);
  } catch (error) {
    console.log(`${name.padEnd(22)} FAIL ${error.message}`);
  }
}
