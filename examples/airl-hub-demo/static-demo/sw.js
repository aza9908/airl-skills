// Статическая демо-версия: офлайн-кэш не нужен, отключаемся.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', () => self.registration.unregister());
