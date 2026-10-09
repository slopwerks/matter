const appBase = new URL('../', self.registration.scope);
const accountUrl = (id) => new URL(`.matter-push/accounts/${encodeURIComponent(id)}`, appBase).href;
const cacheName = `matter-push:${appBase.href}`;

async function accepts(target) {
  if (!target || typeof target.user_id !== 'string' || !target.user_id.startsWith('@') ||
      typeof target.room_id !== 'string' || !target.room_id.startsWith('!') ||
      typeof target.event_id !== 'string' || !target.event_id.startsWith('$') ||
      typeof target.registration_id !== 'string' || !target.registration_id) return false;
  const cache = await caches.open(cacheName);
  const saved = await cache.match(accountUrl(target.user_id));
  if (!saved) return false;
  const state = await saved.json();
  return state.enabled && state.registrationId === target.registration_id;
}

self.addEventListener('install', (event) => event.waitUntil(self.skipWaiting()));
self.addEventListener('push', (event) => {
  event.waitUntil((async () => {
    let payload;
    try { payload = event.data?.json(); } catch { return; }
    // Gateways must preserve the Matrix default_payload account routing.
    const target = payload?.notification || payload;
    if (!await accepts(target)) return;
    await self.registration.showNotification('Matter', {
      body: '你有一条新消息',
      icon: new URL('icons/Icon-192.png', appBase).href,
      tag: `${target.user_id}:${target.event_id}`,
      data: target,
    });
  })());
});
self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  event.waitUntil((async () => {
    const target = event.notification.data;
    if (!await accepts(target)) return;
    const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    const client = windows.find((candidate) => candidate.url.startsWith(appBase.href));
    if (client) {
      client.postMessage({ type: 'matter-push-open', target });
      await client.focus();
    } else {
      await self.clients.openWindow(`${appBase.href}?matter_push=${encodeURIComponent(JSON.stringify(target))}`);
    }
  })());
});
