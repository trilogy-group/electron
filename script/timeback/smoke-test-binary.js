// Smoke test run INSIDE the freshly packaged Electron, as its main process.
//
// Fails the build (non-zero exit) when the packaged binary is not the TimeBack
// Electron we intend to publish. Assertions:
//
//   1. process.versions.electron === SMOKE_EXPECTED_VERSION
//      Proves override_electron_version landed in this zip.
//   2. process.versions.chrome matches SMOKE_EXPECTED_CHROME (default 150.)
//      Guards the Chromium-152 misfire that previously shipped under a 43.2
//      label — crash-fix builds must stay on the DEPS-pinned 150 line.
//   3. net.WebSocket + electron_common_net.createWebSocket exist
//      Upstream Electron 43.3 already ships these; still a cheap proof the
//      Framework/asar pair actually loads (not a hollow/corrupt zip).
//
// Headless main-process only (no window, no network). Watchdog exits non-zero
// if the app never becomes ready.

const { app, net } = require('electron');

const expected = process.env.SMOKE_EXPECTED_VERSION;
const expectedChromePrefix = process.env.SMOKE_EXPECTED_CHROME || '150.';

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

  const chrome = process.versions.chrome || '';
  if (!chrome.startsWith(expectedChromePrefix)) {
    errors.push(
      `chrome version is "${chrome}", expected prefix "${expectedChromePrefix}" ` +
        '(wrong Chromium line for this TimeBack release)'
    );
  }

  if (typeof net.WebSocket !== 'function') {
    errors.push('net.WebSocket is missing — Electron Framework/asar failed to load');
  }

  try {
    const binding = process._linkedBinding('electron_common_net');
    if (typeof binding.createWebSocket !== 'function') {
      errors.push('electron_common_net.createWebSocket missing — native net binding incomplete');
    }
  } catch (e) {
    errors.push(`electron_common_net binding unavailable (${e.message})`);
  }

  if (errors.length) {
    console.error('SMOKE FAIL: ' + errors.join('; '));
    app.exit(1);
  } else {
    console.log(
      `SMOKE OK: electron ${version}, chrome ${chrome}, net.WebSocket + native binding present`
    );
    app.exit(0);
  }
}).catch((e) => {
  clearTimeout(watchdog);
  console.error('SMOKE FAIL: whenReady rejected — ' + (e && e.stack || e));
  app.exit(4);
});
