/* Browser PushManager bridge. The worker has a separate scope so it does not
 * replace Flutter's application worker or intercept navigation/fetches. */
(() => {
  const base = new URL('.', document.baseURI);
  const accountUrl = (id) => new URL(`.matter-push/accounts/${encodeURIComponent(id)}`, base).href;
  const cacheName = `matter-push:${base.href}`;
  let registration;
  let initialTarget = null;
  const listeners = new Set();

  navigator.serviceWorker?.addEventListener('message', (event) => {
    if (event.data?.type !== 'matter-push-open') return;
    if (listeners.size === 0) initialTarget = JSON.stringify(event.data.target);
    else for (const listener of listeners) listener(JSON.stringify(event.data.target));
  });
  try {
    const url = new URL(location.href);
    const launch = url.searchParams.get('matter_push');
    if (launch) {
      initialTarget = JSON.stringify(JSON.parse(launch));
      url.searchParams.delete('matter_push');
      history.replaceState(null, '', url);
    }
  } catch {
    console.warn('Invalid notification launch target');
  }

  window.matterPush = {
    async initialize() {
      if (!isSecureContext || !('PushManager' in window) || !navigator.serviceWorker) {
        throw new Error('浏览器不支持 Web Push，或当前页面不是 HTTPS');
      }
      registration ??= await navigator.serviceWorker.register(
        new URL('matter-push-sw.js', base), { scope: new URL('.matter-push/', base).pathname },
      );
      if (!registration.active) {
        const worker = registration.installing || registration.waiting;
        await new Promise((resolve, reject) => {
          if (!worker) return reject(new Error('推送 Service Worker 不可用'));
          const check = () => {
            if (worker.state === 'activated') resolve();
            if (worker.state === 'redundant') reject(new Error('推送 Service Worker 启动失败'));
          };
          worker.addEventListener('statechange', check);
          check();
        });
      }
    },
    async requestPermission() {
      if (!('Notification' in window) || await Notification.requestPermission() !== 'granted') {
        throw new Error('通知权限未授予，请在浏览器设置中允许 Matter 通知');
      }
    },
    async subscribe(publicKey) {
      if (Notification.permission !== 'granted') throw new Error('通知权限未授予');
      await this.initialize();
      const key = Uint8Array.from(atob(publicKey.replace(/-/g, '+').replace(/_/g, '/')), c => c.charCodeAt(0));
      let subscription = await registration.pushManager.getSubscription();
      if (subscription) {
        const currentKey = new Uint8Array(subscription.options.applicationServerKey);
        if (currentKey.length !== key.length || currentKey.some((byte, i) => byte !== key[i])) {
          throw new Error('此浏览器已订阅另一 VAPID 密钥；请先关闭所有账号的推送并清除此站点的浏览器订阅');
        }
      } else {
        subscription = await registration.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: key });
      }
      return JSON.stringify(subscription.toJSON());
    },
    async subscription() {
      await this.initialize();
      const subscription = await registration.pushManager.getSubscription();
      if (!subscription) throw new Error('浏览器推送订阅不可用，请重新启用推送');
      return JSON.stringify(subscription.toJSON());
    },
    async updateAccount(userId, registrationId, enabled) {
      const cache = await caches.open(cacheName);
      await cache.put(accountUrl(userId), new Response(JSON.stringify({ registrationId, enabled })));
    },
    async roomNotificationEvents(userId, roomId) {
      const saved = registration || await navigator.serviceWorker?.getRegistration(
        new URL('.matter-push/', base).href,
      );
      if (!saved) return '[]';
      const notifications = await saved.getNotifications();
      return JSON.stringify(notifications
        .filter(({ data }) => data?.user_id === userId && data?.room_id === roomId)
        .map(({ data }) => data.event_id));
    },
    async cancelRoomNotifications(userId, roomId, eventIds) {
      const saved = registration || await navigator.serviceWorker?.getRegistration(
        new URL('.matter-push/', base).href,
      );
      if (!saved) return;
      const readEvents = new Set(eventIds);
      for (const notification of await saved.getNotifications()) {
        const data = notification.data;
        if (data?.user_id === userId && data?.room_id === roomId && readEvents.has(data.event_id)) {
          notification.close();
        }
      }
    },
    addOpenListener(listener) { listeners.add(listener); },
    takeInitialTarget() { const target = initialTarget; initialTarget = null; return target; },
  };
})();
