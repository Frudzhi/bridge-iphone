import Foundation

enum BridgeWebIntegration {
  // Adapts only the existing remote-input endpoints. A failed BLE write is never
  // retried via HTTP: the next user gesture can use the network after reconnect.
  static let script = #"""
  (() => {
    if (window.__bridgeNativeInstalled) return;
    window.__bridgeNativeInstalled = true;
    let state = {ready:false, name:'Ноутбук'};
    const originalFetch = window.fetch.bind(window);
    const completed = new Map();
    const response = value => new Response(JSON.stringify(value), {status:200, headers:{'Content-Type':'application/json'}});
    const send = value => window.webkit.messageHandlers.bridgeControl.postMessage(value);
    const render = () => {
      document.querySelector('#nav [data-pc="bridge"]')?.remove();
      document.querySelectorAll('.g.pc, .bridge-control').forEach(root => {
        let button = root.querySelector('.native-bluetooth');
        if (!button) {
          button = document.createElement('button');
          button.className = 'cta alt native-bluetooth';
          button.type = 'button';
          button.addEventListener('click', () => {
            let key = null; try { key = localStorage.getItem('shtab_key'); } catch {}
            send({op:'setup', key}).catch(() => {});
          });
          root.append(button);
        }
        const text = state.ready ? 'Bluetooth · ' + state.name : 'Подключить Bluetooth';
        if (button.textContent !== text) button.textContent = text;
      });
      const status = document.querySelector('#br-status');
      if (state.ready && status && status.textContent !== state.name + ' · Bluetooth') status.textContent = state.name + ' · Bluetooth';
      const hint = document.querySelector('.bridge-control .br-hint');
      const text = state.ready ? 'Прямое соединение Bluetooth. Интернет для управления не нужен.' : 'Если Bluetooth недоступен — управление через интернет.';
      if (hint && hint.textContent !== text) hint.textContent = text;
    };
    window.__setBridgeNativeState = value => {
      const previous = state.ready;
      state = value;
      render();
      // Existing control panel creates a fresh session and polls immediately.
      if (previous !== state.ready) document.dispatchEvent(new Event('visibilitychange'));
    };
    window.fetch = async (input, init) => {
      let url;
      try { url = new URL(typeof input === 'string' || input instanceof URL ? input : input.url, location.href); }
      catch { return originalFetch(input, init); }
      if (url.origin !== location.origin) return originalFetch(input, init);
      const path = url.pathname;
      const method = (init?.method || input?.method || 'GET').toUpperCase();
      for (const [id,time] of completed) if (Date.now()-time > 30000) completed.delete(id);
      if (method === 'GET' && path.startsWith('/api/pc/cmd/')) {
        const id = path.slice('/api/pc/cmd/'.length);
        if (completed.has(id)) return response({status:'done', result:{ok:true,transport:'bluetooth'}});
      }
      if (state.ready && path === '/api/pc/control') {
        if (method === 'POST') return response({ok:true});
        if (method === 'GET') return response({pc:{host:state.name,updated_at:new Date().toISOString(),bridge:{remoteInput:true}}});
      }
      if (state.ready && method === 'POST' && path === '/api/pc/input') {
        const body = typeof init?.body === 'string' ? init.body : input instanceof Request ? await input.clone().text() : '{}';
        const packet = JSON.parse(body);
        await send({op:'input',events:packet.events});
        const id = 'ble-' + crypto.randomUUID();
        completed.set(id,Date.now());
        return response({id});
      }
      return originalFetch(input, init);
    };
    new MutationObserver(render).observe(document.body, {childList:true,subtree:true});
    render();
  })();
  """#
}
