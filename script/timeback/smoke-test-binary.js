// Smoke test run INSIDE the freshly packaged Electron, as its main process.
//
// It fails the build (non-zero exit) when the packaged binary is not the
// TimeBack patched Electron we intend to publish. Two independent assertions:
//
//   1. process.versions.electron === the version we are shipping. Proves the
//      zip we are about to publish is this build, not a stale or stock one.
//   2. The fetch-intercept patch set is actually present, end to end:
//        - net.WebSocket (the JS class this branch adds) is a function, proving
//          the patched app.asar shipped, and
//        - the electron_common_net native binding exposes createWebSocket,
//          proving the C++ side (electron_api_web_socket.cc) compiled into the
//          Electron Framework. Stock Electron 43 has neither.
//
// Runs headless (main process only, no window, no network) so it is safe on a
// CI runner with no display. A watchdog exits non-zero if the app never readies.

const { app, net } = require('electron');

const expected = process.env.SMOKE_EXPECTED_VERSION;

const watchdog = setTimeout(() => {
  console.error('SMOKE FAIL: app did not become ready within 60s');
  app.exit(3);
}, 60000);
watchdog.unref?.();

app.whenReady().then(() => {
  clearTimeout(watchdog);
  const errors = [];

  const version = process.versions.electron;
  if (!expected) {
    errors.push('SMOKE_EXPECTED_VERSION was not set');
  } else if (version !== expected) {
    errors.push(`electron version is "${version}", expected "${expected}"`);
  }

  if (typeof net.WebSocket !== 'function') {
    errors.push('net.WebSocket is missing — fetch-intercept patch (app.asar) not shipped');
  }

  try {
    const binding = process._linkedBinding('electron_common_net');
    if (typeof binding.createWebSocket !== 'function') {
      errors.push('electron_common_net.createWebSocket missing — native patch not compiled in');
    }
  } catch (e) {
    errors.push(`electron_common_net binding unavailable — native patch not compiled in (${e.message})`);
  }

  if (errors.length) {
    console.error('SMOKE FAIL: ' + errors.join('; '));
    app.exit(1);
  } else {
    console.log(`SMOKE OK: electron ${version}, net.WebSocket + native binding present`);
    app.exit(0);
  }
}).catch((e) => {
  clearTimeout(watchdog);
  console.error('SMOKE FAIL: whenReady rejected — ' + (e && e.stack || e));
  app.exit(4);
});
