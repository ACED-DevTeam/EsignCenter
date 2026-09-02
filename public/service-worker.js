self.addEventListener('install', () => {
  console.log('EsignCenter App installed')
})

self.addEventListener('activate', () => {
  console.log('EsignCenter App activated')
})

self.addEventListener('fetch', (event) => {
  event.respondWith(fetch(event.request))
})
