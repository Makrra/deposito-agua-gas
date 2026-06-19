const CACHE = 'deposito-agua-v2';
const ASSETS = ['./', './index.html', './manifest.json', './icon-192.png', './icon-512.png'];

self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(CACHE).then((cache) => cache.addAll(ASSETS)));
  self.skipWaiting();
});

self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k)))
    )
  );
  self.clients.claim();
});

// Network-first: sempre busca a versão mais recente; usa o cache só se
// estiver offline. Evita o app ficar "travado" numa versão antiga.
self.addEventListener('fetch', (e) => {
  // Supabase requests sempre vão para a rede (dados precisam ser atuais)
  if (e.request.url.includes('supabase.co')) return;

  // 'reload' ignora o cache HTTP do navegador (o GitHub Pages manda
  // Cache-Control: max-age=600, então sem isso a "busca na rede" podia
  // devolver uma resposta de até 10min atrás mesmo estando online)
  e.respondWith(
    fetch(e.request, { cache: 'reload' })
      .then((res) => {
        const resClone = res.clone();
        caches.open(CACHE).then((cache) => cache.put(e.request, resClone));
        return res;
      })
      .catch(() => caches.match(e.request))
  );
});
