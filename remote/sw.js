// Only a generic offline document is cached. Passwords, sessions, HTML app responses,
// project/task data, and API responses are never put in Cache Storage.
const CACHE = 'jess-offline-v1';
self.addEventListener('install', event => {
  event.waitUntil(caches.open(CACHE).then(cache => cache.add('/offline.html')));
});
self.addEventListener('activate', event => {
  event.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(key => key.startsWith('jess-offline-') && key !== CACHE).map(key => caches.delete(key)))));
});
self.addEventListener('fetch', event => {
  const url = new URL(event.request.url);
  if (event.request.mode !== 'navigate' || url.origin !== self.location.origin || event.request.method !== 'GET') return;
  event.respondWith(fetch(event.request).catch(async () => (await caches.match('/offline.html')) ?? Response.error()));
});
