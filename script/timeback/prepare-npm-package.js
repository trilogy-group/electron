#!/usr/bin/env node
// Turn the upstream npm/ template into the publishable @trilogy-group/electron package.
//
// This lives in the repo rather than inline in the workflow so it can be run and
// tested locally (see test-prepare-npm-package.sh) instead of only discovering
// mistakes after a publish.
//
// Usage: prepare-npm-package.js <staging-dir>
//   env: ELECTRON_VERSION, TIMEBACK_ELECTRON_MIRROR

const fs = require('fs');
const path = require('path');

const stagingDir = process.argv[2];
const version = process.env.ELECTRON_VERSION;
const mirror = process.env.TIMEBACK_ELECTRON_MIRROR;

for (const [name, value] of Object.entries({ stagingDir, ELECTRON_VERSION: version, TIMEBACK_ELECTRON_MIRROR: mirror })) {
  if (!value) {
    console.error(`prepare-npm-package: ${name} is required`);
    process.exit(1);
  }
}

if (!mirror.endsWith('/')) {
  // @electron/get concatenates mirror + customDir; a missing slash silently
  // produces a 404 URL instead of an error.
  console.error(`prepare-npm-package: mirror must end with "/" (got ${mirror})`);
  process.exit(1);
}

const pkgPath = path.join(stagingDir, 'package.json');
const pkg = JSON.parse(fs.readFileSync(pkgPath, 'utf8'));

pkg.name = '@trilogy-group/electron';
pkg.version = version;
pkg.description = 'Electron with TimeBack Chromium patches';
pkg.license = 'MIT';
pkg.repository = {
  type: 'git',
  url: 'git+https://github.com/trilogy-group/electron.git'
};
pkg.publishConfig = {
  registry: 'https://npm.pkg.github.com'
};
pkg.config = {
  ...(pkg.config || {}),
  electron_mirror: mirror,
  electron_custom_dir: `v${version}`
};

fs.writeFileSync(pkgPath, JSON.stringify(pkg, null, 2) + '\n');

// The binary download is lazy: index.js shells out to install.js on the first
// require(), so npm is not involved and npm_config_electron_mirror (from pkg.config
// above) is never set. Baking the mirror into install.js is what actually redirects
// @electron/get at our Releases.
const installPath = path.join(stagingDir, 'install.js');
let install = fs.readFileSync(installPath, 'utf8');

if (!install.includes('TIMEBACK_MIRROR_INJECTED')) {
  const anchor = 'downloadArtifact({';
  if (!install.includes(anchor)) {
    console.error(`prepare-npm-package: could not find "${anchor}" in install.js — upstream shape changed`);
    process.exit(1);
  }
  install = install.replace(
    anchor,
    `// TIMEBACK_MIRROR_INJECTED\nprocess.env.ELECTRON_MIRROR = process.env.ELECTRON_MIRROR || '${mirror}';\n${anchor}`
  );
  fs.writeFileSync(installPath, install);
}

if (!fs.readFileSync(installPath, 'utf8').includes('TIMEBACK_MIRROR_INJECTED')) {
  console.error('prepare-npm-package: mirror injection did not stick');
  process.exit(1);
}

// checksums.json is in the package `files` list and install.js require()s it, so a
// missing or empty one breaks every install with a confusing stack trace.
const checksumsPath = path.join(stagingDir, 'checksums.json');
if (!fs.existsSync(checksumsPath)) {
  console.error('prepare-npm-package: checksums.json missing from staging dir');
  process.exit(1);
}
const checksums = JSON.parse(fs.readFileSync(checksumsPath, 'utf8'));
const expectedPrefix = `electron-v${version}-`;
const names = Object.keys(checksums);
if (names.length === 0) {
  console.error('prepare-npm-package: checksums.json is empty');
  process.exit(1);
}
const mismatched = names.filter((n) => !n.startsWith(expectedPrefix));
if (mismatched.length > 0) {
  console.error(
    `prepare-npm-package: checksums.json keys do not match version ${version}: ${mismatched.join(', ')}`
  );
  process.exit(1);
}

console.log(`Prepared ${pkg.name}@${pkg.version}`);
console.log(`  mirror:    ${mirror}v${version}/`);
console.log(`  platforms: ${names.join(', ')}`);
