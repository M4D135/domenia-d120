import { call } from './bridge.js';

const app = document.getElementById('app');
call('app.info')
  .then((info) => { app.innerHTML = `<p class="boot">${info.name} ${info.version} — moteur web ${info.webViewRuntime}, .NET ${info.runtime}</p>`; })
  .catch((err) => { app.innerHTML = `<p class="boot">${err.message}</p>`; });
