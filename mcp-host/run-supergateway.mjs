// Supergateway currently listens on every network interface and has no host
// option. Open WebUI reaches Windows loopback through host.docker.internal, so
// force the local gateway to bind only to 127.0.0.1.
import net from 'node:net';

const originalListen = net.Server.prototype.listen;

net.Server.prototype.listen = function listenOnLoopback(...args) {
  if (typeof args[0] === 'number') {
    if (typeof args[1] === 'function' || args[1] === undefined) {
      args.splice(1, 0, '127.0.0.1');
    } else if (typeof args[1] === 'string') {
      args[1] = '127.0.0.1';
    }
  } else if (args[0] && typeof args[0] === 'object') {
    args[0] = { ...args[0], host: '127.0.0.1' };
  }

  return originalListen.apply(this, args);
};

await import('./node_modules/supergateway/dist/index.js');
