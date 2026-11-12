
const CACHE_NAME = 'okinawa-map-v45';
const MAP_URL = './assets/assets/maps/okinawa_north.pmtiles';


self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then(async (cache) => {
      await cache.add(MAP_URL);


      await cache.addAll([
        './',
        './index.html',
        './flutter_bootstrap.js',
        './flutter.js',
        './main.dart.js',
        './manifest.json',
        './assets/AssetManifest.bin',
        './assets/FontManifest.json',
        './assets/assets/fonts/NotoSansJP.ttf',
        './assets/fonts/MaterialIcons-Regular.otf',
        './assets/shaders/ink_sparkle.frag',
        './assets/shaders/stretch_effect.frag',
        './canvaskit/canvaskit.js',
        './canvaskit/canvaskit.wasm',
        './canvaskit/chromium/canvaskit.js',
        './canvaskit/chromium/canvaskit.wasm',
      ]);
    })
  );
});


self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    const cacheNames = await caches.keys();

    await Promise.all(
      cacheNames
        .filter((name) =>
          name.startsWith('okinawa-map-v') &&
          name !== CACHE_NAME
        )
        .map((name) => caches.delete(name))
    );

    await self.clients.claim();
  })());
});



self.addEventListener('fetch', (event) => {
  const url = new URL(event.request.url);
  const mapUrl = new URL(MAP_URL, self.registration.scope);

  if (url.origin !== self.location.origin) {
  return;
}

  // 地図以外の同一オリジンのファイルは、
  // 通信できない場合にキャッシュから読み込む
  if (url.origin === self.location.origin &&
      url.pathname !== mapUrl.pathname) {
    event.respondWith((async () => {
      try {
        return await fetch(event.request);
      } catch (_) {
        const cache = await caches.open(CACHE_NAME);
        const cached = await cache.match(event.request);

        if (cached) return cached;

        throw new Error('オフライン用キャッシュがありません');
      }
    })());
    return;
  }


  event.respondWith((async () => {
    const cache = await caches.open(CACHE_NAME);
    const cached = await cache.match(mapUrl.href);

    if (!cached) {
      return fetch(event.request);
    }

    const range = event.request.headers.get('Range');

    // 通常のリクエストにはファイル全体を返す
    if (!range) {
      return cached;
    }

    const match = /^bytes=(\d+)-(\d*)$/.exec(range);

    if (!match) {
      return new Response(null, { status: 416 });
    }

    const buffer = await cached.arrayBuffer();
    const size = buffer.byteLength;
    const start = Number(match[1]);
    const end = match[2]
        ? Number(match[2])
        : size - 1;

    if (start >= size || end < start) {
      return new Response(null, {
        status: 416,
        headers: {
          'Content-Range': `bytes */${size}`,
        },
      });
    }

    const actualEnd = Math.min(end, size - 1);
    const chunk = buffer.slice(start, actualEnd + 1);

    return new Response(chunk, {
      status: 206,
      headers: {
        'Content-Type': 'application/octet-stream',
        'Accept-Ranges': 'bytes',
        'Content-Range':
            `bytes ${start}-${actualEnd}/${size}`,
        'Content-Length': String(chunk.byteLength),
      },
    });
  })());
});
