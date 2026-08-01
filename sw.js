// سێرڤس وۆرکەر — هەڵگرتنی پەڕەکان بۆ کارکردن بەبێ ئینتەرنێت (شێوەکار + دوایین داتای هاوکاتکراو)
const CACHE = 'barber-app-v1';
const ASSETS = [
  './dashboard.html',
  './booking.html',
  './admin.html',
  './manifest.json',
  './icon-192.png',
  './icon-512.png',
  './icon-180.png',
  './favicon-32.png'
];

self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(ASSETS)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys().then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (e) => {
  // پۆستەکان (بانگکردنی API) بەبێ دەستکاری دەردەچن — تەنها GET ی ناوخۆیی cache دەکرێت
  if (e.request.method !== 'GET') return;
  if (!e.request.url.startsWith(self.location.origin)) return;

  e.respondWith(
    caches.match(e.request).then((cached) => {
      const network = fetch(e.request)
        .then((res) => {
          if (res && res.status === 200) {
            caches.open(CACHE).then((c) => c.put(e.request, res.clone()));
          }
          return res;
        })
        .catch(() => cached);
      return cached || network;
    })
  );
});
