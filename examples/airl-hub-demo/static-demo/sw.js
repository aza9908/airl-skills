// Статическая демо-версия: офлайн-кэш не нужен, отключаемся (и снимаем service worker прошлых версий).
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', () => self.registration.unregister());
