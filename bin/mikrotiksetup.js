#!/usr/bin/env node

/** mikrotiksetup — set up a LokalFi MikroTik from a terminal. */

const { spawnSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');
const readline = require('readline/promises');

const C = {
  B: '\x1b[0;34m',
  G: '\x1b[0;32m',
  Y: '\x1b[1;33m',
  R: '\x1b[0;31m',
  NC: '\x1b[0m',
};

const TOOL_ROOT = path.resolve(__dirname, '..');
const GOLD_DIR = path.join(TOOL_ROOT, 'backup', '2026-09-17');
const CONFIG_DIR = path.join(os.homedir(), '.config', 'mikrotiksetup');
const CONFIG_PATH = path.join(CONFIG_DIR, 'config.json');
const DEFAULT_PORTAL = path.join(os.homedir(), 'Developer', 'lokalfi', 'lokalfi-captive-portal');
const GOLD_CREDS = { user: 'admin', password: 'lokalfi.net' };
const GOLD_LAN = '192.168.10.1';
const LAB_SERIAL = 'HJC0A5MY028';

function info(t) {
  console.log(`${C.B}[INFO]${C.NC} ${t}`);
}
function ok(t) {
  console.log(`${C.G}[SUCCESS]${C.NC} ${t}`);
}
function warn(t) {
  console.log(`${C.Y}[WARNING]${C.NC} ${t}`);
}
function err(t) {
  console.log(`${C.R}[ERROR]${C.NC} ${t}`);
}

function loadConfig() {
  if (!fs.existsSync(CONFIG_PATH)) {
    return { captivePortalPath: DEFAULT_PORTAL };
  }
  try {
    const j = JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8'));
    return { captivePortalPath: j.captivePortalPath || DEFAULT_PORTAL };
  } catch {
    return { captivePortalPath: DEFAULT_PORTAL };
  }
}

function saveConfig(cfg) {
  fs.mkdirSync(CONFIG_DIR, { recursive: true, mode: 0o700 });
  fs.writeFileSync(CONFIG_PATH, JSON.stringify(cfg, null, 2) + '\n', { mode: 0o600 });
}

function portalRoot() {
  const p = loadConfig().captivePortalPath;
  if (!fs.existsSync(path.join(p, 'package.json'))) {
    err(`Portal repo not found: ${p}. Run: mikrotiksetup config`);
    process.exit(1);
  }
  return p;
}

function goldFile(model) {
  const name = model === 'E50UG' ? 'E50UG-config.backup' : 'RB750Gr3-config.backup';
  const f = path.join(GOLD_DIR, name);
  if (!fs.existsSync(f)) {
    err(`Backup file missing: ${f}`);
    process.exit(1);
  }
  return f;
}

function readDotenv(file) {
  const out = {};
  if (!fs.existsSync(file)) return out;
  for (const line of fs.readFileSync(file, 'utf8').split('\n')) {
    const t = line.trim();
    if (!t || t.startsWith('#')) continue;
    const i = t.indexOf('=');
    if (i < 1) continue;
    let v = t.slice(i + 1).trim();
    if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) {
      v = v.slice(1, -1);
    }
    out[t.slice(0, i).trim()] = v;
  }
  return out;
}

function nucLanIp(root) {
  const env = readDotenv(path.join(root, 'deployment/docker/.env'));
  return process.env.NUC_LAN_IP || env.NEXT_PUBLIC_NUC_LAN_IP || env.NUC_LAN_IP || '192.168.10.220';
}

function warnEnvMismatch(root) {
  const env = readDotenv(path.join(root, 'deployment/docker/.env'));
  const ip = env.NEXT_PUBLIC_MIKROTIK_MANAGEMENT_IP || env.MIKROTIK_HOST;
  const user = env.MIKROTIK_USER || env.NEXT_PUBLIC_MIKROTIK_USER || 'admin';
  const pass = env.MIKROTIK_PASSWORD || env.NEXT_PUBLIC_MIKROTIK_PASSWORD;
  if (ip && ip !== GOLD_LAN) {
    warn(`deployment/docker/.env management IP is ${ip}; after restore the router is ${GOLD_LAN}.`);
  }
  if (pass && pass !== GOLD_CREDS.password) {
    warn('deployment/docker/.env MikroTik password is not lokalfi.net. The app API may miss this router.');
  }
  if (user && user !== GOLD_CREDS.user) {
    warn(`deployment/docker/.env MikroTik user is ${user}; after restore it is admin.`);
  }
}

function sshOk(host, user, password, cmd = '/system identity print') {
  if (!password || !commandExists('sshpass')) {
    const r = spawnSync('ssh', ['-p', '22', '-o', 'StrictHostKeyChecking=accept-new', '-o', 'ConnectTimeout=8', '-o', 'BatchMode=yes', `${user}@${host}`, cmd], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    return r.status === 0 ? r.stdout || ' ' : null;
  }
  const r = spawnSync('sshpass', ['-e', 'ssh', '-p', '22', '-o', 'StrictHostKeyChecking=accept-new', '-o', 'ConnectTimeout=8', `${user}@${host}`, cmd], {
    encoding: 'utf8',
    env: { ...process.env, SSHPASS: password },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  return r.status === 0 ? r.stdout || ' ' : null;
}

function commandExists(name) {
  return spawnSync('sh', ['-c', `command -v ${name}`], { encoding: 'utf8' }).status === 0;
}

function parseRouterboard(text) {
  const model = (text.match(/^\s*model:\s*(.+)$/m) || [])[1];
  let serial = (text.match(/^\s*serial-number:\s*(.+)$/m) || [])[1];
  if (!serial) serial = (text.match(/^\s*serial number:\s*(.+)$/m) || [])[1];
  return {
    model: model ? model.trim() : '',
    serial: serial ? serial.trim() : '',
  };
}

function modelLabel(model) {
  const m = (model || '').trim();
  if (/^e50ug$/i.test(m)) return 'E50UG';
  if (/^rb750gr3$/i.test(m)) return 'RB750Gr3';
  return '';
}

const TOOL_SCRIPTS = {
  restore: 'mikrotik-restore-backup.sh',
  formatSd: 'mikrotik-format-sd.sh',
  upload: 'upload-hotspot-to-mikrotik.sh',
  wan: 'mikrotik-fix-wan-internet.sh',
  parity: 'mikrotik-router-parity-fix.sh',
  deviceMode: 'mikrotik-enable-hotspot-device-mode.sh',
  portalNetwork: 'mikrotik-apply-portal-network.sh',
  pull: 'mikrotik-pull-backup.sh',
};

function toolEnv(extra = {}) {
  return {
    ...process.env,
    MIKROTIK_PORTAL_ROOT: portalRoot(),
    ...extra,
  };
}

function runTool(scriptFile, extra = [], extraEnv = {}) {
  const script = path.join(TOOL_ROOT, 'scripts', scriptFile);
  if (!fs.existsSync(script)) {
    err(`Missing ${script}`);
    return 1;
  }
  info(`bash scripts/${scriptFile}${extra.length ? ' ' + extra.join(' ') : ''}`);
  const r = spawnSync('bash', [script, ...extra], {
    stdio: 'inherit',
    env: toolEnv(extraEnv),
  });
  return r.status || 0;
}

function probeFormatSlots(host, extraEnv) {
  const script = path.join(TOOL_ROOT, 'scripts', TOOL_SCRIPTS.formatSd);
  const r = spawnSync('bash', [script, '--probe', host], {
    encoding: 'utf8',
    env: toolEnv(extraEnv),
  });
  const slots = String(r.stdout || '')
    .split('\n')
    .map((s) => s.trim())
    .filter((s) => /^(sd|usb|disk)[0-9]+$/i.test(s));
  return { status: r.status == null ? 1 : r.status, slots, stderr: r.stderr || '' };
}

function mikrotikEnv(sess, extra = {}) {
  return {
    MIKROTIK_HOST: sess.host,
    MIKROTIK_USER: sess.user,
    MIKROTIK_PASSWORD: sess.password,
    ...extra,
  };
}

function printHelp() {
  console.log(`mikrotiksetup — set up a LokalFi MikroTik from a terminal

Usage:
  mikrotiksetup                 menu (Enter = full setup)
  mikrotiksetup setup           full setup
  mikrotiksetup setup --skip-restore   skip restore; continue from device-mode
  mikrotiksetup config          set path to lokalfi-captive-portal
  mikrotiksetup upload-hotspot
  mikrotiksetup wan
  mikrotiksetup device-mode
  mikrotiksetup apply-portal-network
  mikrotiksetup pull-backup
  mikrotiksetup restore
  mikrotiksetup format-sd
  mikrotiksetup bootstrap

A new router is often 192.168.88.1. This PC must already be on that subnet, or you add 192.168.88.x yourself.
After restore: 192.168.10.1 on ether2-LAN, admin / lokalfi.net. Device-mode still needs a short reset tap on the box.

Restore loads the 17 Sep 2026 backup for this model (July voucher set, not a blank router).
Lab serial ${LAB_SERIAL} is blocked unless --force.
scripts/ talks to the router. The portal checkout supplies hotspot HTML, docker/.env, and Mongo.
`);
}

async function prompt(rl, q, def) {
  const hint = def ? ` [${def}]` : '';
  const a = (await rl.question(`${C.B}[INFO]${C.NC} ${q}${hint}: `)).trim();
  return a || def || '';
}

async function probeSession(rl) {
  let host = await prompt(rl, 'Router IP', GOLD_LAN);
  info(`Trying ${GOLD_CREDS.user} / lokalfi.net on ${host} ...`);
  let out = sshOk(host, GOLD_CREDS.user, GOLD_CREDS.password, '/system routerboard print');
  if (out) {
    ok('Logged in with existing LokalFi credentials.');
    return { host, user: GOLD_CREDS.user, password: GOLD_CREDS.password, rb: parseRouterboard(out) };
  }
  if (host !== GOLD_LAN) {
    info(`Trying ${GOLD_LAN} with the same credentials ...`);
    out = sshOk(GOLD_LAN, GOLD_CREDS.user, GOLD_CREDS.password, '/system routerboard print');
    if (out) {
      ok(`Reached ${GOLD_LAN} with LokalFi credentials.`);
      return { host: GOLD_LAN, user: GOLD_CREDS.user, password: GOLD_CREDS.password, rb: parseRouterboard(out) };
    }
  }
  warn('admin / lokalfi.net failed. Treat as a new router. Sticker user/password next.');
  warn('If the IP is 192.168.88.1, this PC must already be on that subnet.');
  const user = await prompt(rl, 'SSH user', 'admin');
  const password = await prompt(rl, 'SSH password (sticker)', '');
  if (!password) {
    err('Password required for a factory router.');
    process.exit(1);
  }
  out = sshOk(host, user, password, '/system routerboard print');
  if (!out) {
    err(`SSH failed to ${user}@${host}. Check IP, cable, and subnet.`);
    process.exit(1);
  }
  info('Setting admin password to lokalfi.net (RouterOS often requires a change after first login).');
  const setPw = sshOk(host, user, password, '/user set [find name=admin] password="lokalfi.net"');
  if (setPw === null) {
    warn('Could not set admin password. Restore may still set admin / lokalfi.net.');
    return { host, user, password, rb: parseRouterboard(out), factory: true };
  }
  const again = sshOk(host, GOLD_CREDS.user, GOLD_CREDS.password, '/system routerboard print');
  if (again) {
    ok('admin / lokalfi.net works.');
    return { host, user: GOLD_CREDS.user, password: GOLD_CREDS.password, rb: parseRouterboard(again), factory: true };
  }
  return { host, user, password, rb: parseRouterboard(out), factory: true };
}

function requireModel(sess) {
  const label = modelLabel(sess.rb.model);
  if (!label) {
    err(`Unsupported model '${sess.rb.model}'. Only E50UG and RB750Gr3.`);
    process.exit(1);
  }
  return label;
}

function portalAppRunning() {
  const r = spawnSync('docker', ['inspect', '-f', '{{.State.Running}}', 'lokalfi-captive-portal-app'], {
    encoding: 'utf8',
  });
  return r.status === 0 && String(r.stdout).trim() === 'true';
}

function runBootstrap(root) {
  if (!portalAppRunning()) {
    warn('Portal app container is not running. Start the Docker stack, then: mikrotiksetup bootstrap');
    return 1;
  }
  info('npm run docker:bootstrap-mikrotik');
  const r = spawnSync('npm', ['run', 'docker:bootstrap-mikrotik'], {
    cwd: root,
    stdio: 'inherit',
  });
  return r.status || 0;
}

function uploadHotspot(host, extraEnv, disk) {
  if (runTool(TOOL_SCRIPTS.upload, [host], { ...extraEnv, MIKROTIK_ROUTER_FILES_DISK: disk }) !== 0) {
    warn('Upload failed. Retry: mikrotiksetup upload-hotspot');
    return false;
  }
  return true;
}

async function resolveRb750Slot(rl, host, extraEnv) {
  for (;;) {
    const probe = probeFormatSlots(host, extraEnv);
    if (probe.slots.length === 1) {
      info(`Mounted removable disk: ${probe.slots[0]}`);
      return probe.slots[0];
    }
    if (probe.slots.length === 0) {
      if (!process.stdin.isTTY) {
        warn('No SD card. Using internal flash.');
        return null;
      }
      const a = await prompt(
        rl,
        'No SD card. Press Enter to use flash, or type retry after inserting a card',
        ''
      );
      if (a.toLowerCase() === 'retry') continue;
      warn('Using internal flash.');
      return null;
    }
    info('More than one mounted removable disk:');
    probe.slots.forEach((s) => console.log(`  ${s}`));
    return await prompt(rl, 'Slot to format', probe.slots[0]);
  }
}

async function cmdSetup(rl, { forceRestore = false, skipRestore = false } = {}) {
  const root = portalRoot();
  warnEnvMismatch(root);
  const sess = await probeSession(rl);
  const model = requireModel(sess);
  info(`Model ${model} serial ${sess.rb.serial || '?'}`);

  const env = mikrotikEnv(sess);
  if (runTool(TOOL_SCRIPTS.deviceMode, [sess.host], env) !== 0) {
    warn('Device-mode CLI finished with an error. Tap reset or power-cycle if the router asked for it, then continue.');
  }

  let after = {
    host: sess.host,
    user: sess.user,
    password: sess.password,
    rb: sess.rb,
  };

  if (!skipRestore) {
    const restoreArgs = ['--file', goldFile(model), '--wait', sess.host];
    if (forceRestore || sess.rb.serial === LAB_SERIAL) {
      if (sess.rb.serial === LAB_SERIAL && !forceRestore) {
        err(`Refusing lab serial ${LAB_SERIAL}. Re-run with: mikrotiksetup restore --force`);
        process.exit(1);
      }
      restoreArgs.splice(2, 0, '--force');
    }
    if (runTool(TOOL_SCRIPTS.restore, restoreArgs, env) !== 0) {
      process.exit(1);
    }
    after = {
      host: GOLD_LAN,
      user: GOLD_CREDS.user,
      password: GOLD_CREDS.password,
    };
    const rbOut = sshOk(after.host, after.user, after.password, '/system routerboard print');
    if (!rbOut) {
      err(`No SSH on ${GOLD_LAN} after restore. Plug this PC into ether2-LAN on 192.168.10.0/24.`);
      process.exit(1);
    }
    after.rb = parseRouterboard(rbOut);
  }

  const afterModel = requireModel(after);
  if (afterModel !== model) {
    err(`Model changed after restore (${model} → ${afterModel}). Stop.`);
    process.exit(1);
  }

  info('Re-checking device-mode hotspot=yes ...');
  runTool(TOOL_SCRIPTS.deviceMode, ['--verify-only', after.host], mikrotikEnv(after));

  const afterEnv = mikrotikEnv(after);
  if (afterModel === 'RB750Gr3') {
    if (runTool(TOOL_SCRIPTS.wan, [after.host], afterEnv) !== 0) {
      warn('WAN fix returned non-zero. Continuing.');
    }
    const slot = await resolveRb750Slot(rl, after.host, afterEnv);
    if (!slot) {
      uploadHotspot(after.host, afterEnv, 'flash');
    } else {
      const fmtRc = runTool(TOOL_SCRIPTS.formatSd, ['--yes', '--slot', slot, after.host], afterEnv);
      if (fmtRc !== 0) {
        warn('SD did not mount after format. Uploading hotspot to internal flash.');
        uploadHotspot(after.host, afterEnv, 'flash');
      } else {
        const uploadDisk = /-part[0-9]+$/i.test(slot) ? slot : `${slot}-part1`;
        uploadHotspot(after.host, afterEnv, uploadDisk);
      }
    }
  } else {
    uploadHotspot(after.host, afterEnv, 'flash');
  }

  const lan = nucLanIp(root);
  if (runTool(TOOL_SCRIPTS.portalNetwork, [after.host], { ...afterEnv, NUC_LAN_IP: lan }) !== 0) {
    warn('Portal network failed. Retry: mikrotiksetup apply-portal-network');
  }

  runBootstrap(root);
  ok(`Done. ${afterModel} html on the router. Guest portal: http://lokalfi.net/login.html`);
}

async function cmdRestore(rl, force) {
  const sess = await probeSession(rl);
  const model = requireModel(sess);
  const args = ['--file', goldFile(model), sess.host];
  if (force) args.splice(2, 0, '--force');
  process.exit(runTool(TOOL_SCRIPTS.restore, args, mikrotikEnv(sess)));
}

async function cmdFormat(rl) {
  const sess = await probeSession(rl);
  process.exit(runTool(TOOL_SCRIPTS.formatSd, [sess.host], mikrotikEnv(sess)));
}

function wrap(scriptFile, extra = [], extraEnv = {}) {
  const host = process.env.MIKROTIK_HOST || GOLD_LAN;
  const env = {
    MIKROTIK_HOST: host,
    MIKROTIK_USER: process.env.MIKROTIK_USER || GOLD_CREDS.user,
    MIKROTIK_PASSWORD: process.env.MIKROTIK_PASSWORD || GOLD_CREDS.password,
    ...extraEnv,
  };
  process.exit(runTool(scriptFile, extra.length ? extra : [host], env));
}

async function menu(rl) {
  console.log('');
  info('What do you want to run?');
  console.log('  1) Full setup');
  console.log('  2) Upload hotspot files');
  console.log('  3) Fix WAN / internet');
  console.log('  4) Enable hotspot device-mode');
  console.log('  5) Point the hotspot at the app');
  console.log('  6) Save a backup from this router');
  console.log('  7) Restore the 17 Sep backup');
  console.log('  8) Format SD card (RB750)');
  console.log('  9) Copy router accounts into the app');
  const choice = await prompt(rl, 'Choice', '1');
  switch (choice) {
    case '1':
      await cmdSetup(rl, { forceRestore: false });
      break;
    case '2':
      wrap(TOOL_SCRIPTS.upload);
      break;
    case '3':
      wrap(TOOL_SCRIPTS.wan);
      break;
    case '4':
      wrap(TOOL_SCRIPTS.deviceMode);
      break;
    case '5':
      wrap(TOOL_SCRIPTS.portalNetwork, [], { NUC_LAN_IP: nucLanIp(portalRoot()) });
      break;
    case '6':
      wrap(TOOL_SCRIPTS.pull);
      break;
    case '7':
      await cmdRestore(rl, false);
      break;
    case '8':
      await cmdFormat(rl);
      break;
    case '9':
      process.exit(runBootstrap(portalRoot()));
      break;
    default:
      err('Unknown choice.');
      process.exit(1);
  }
}

async function configCmd(rl) {
  const cur = loadConfig();
  const p = await prompt(rl, 'Path to lokalfi-captive-portal', cur.captivePortalPath);
  saveConfig({ captivePortalPath: p });
  ok(`Saved ${CONFIG_PATH}`);
}

async function main() {
  const raw = process.argv.slice(2);
  const force = raw.includes('--force');
  const skipRestore = raw.includes('--skip-restore');
  const argv = raw.filter((a) => a !== '--force' && a !== '--skip-restore');
  const first = argv[0];

  if (first === '--help' || first === '-h' || first === 'help') {
    printHelp();
    return;
  }

  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  try {
    if (!first) {
      await menu(rl);
      return;
    }
    if (first === 'config') {
      await configCmd(rl);
      return;
    }
    if (first === 'setup' || first === 'everything') {
      await cmdSetup(rl, { forceRestore: force, skipRestore });
      return;
    }
    if (first === 'restore') {
      await cmdRestore(rl, force);
      return;
    }
    if (first === 'format-sd') {
      await cmdFormat(rl);
      return;
    }
    if (first === 'upload-hotspot') {
      wrap(TOOL_SCRIPTS.upload);
      return;
    }
    if (first === 'wan') {
      wrap(TOOL_SCRIPTS.wan);
      return;
    }
    if (first === 'router-parity-fix') {
      wrap(TOOL_SCRIPTS.parity);
      return;
    }
    if (first === 'device-mode') {
      wrap(TOOL_SCRIPTS.deviceMode);
      return;
    }
    if (first === 'apply-portal-network') {
      wrap(TOOL_SCRIPTS.portalNetwork, [], { NUC_LAN_IP: nucLanIp(portalRoot()) });
      return;
    }
    if (first === 'pull-backup') {
      wrap(TOOL_SCRIPTS.pull);
      return;
    }
    if (first === 'bootstrap') {
      process.exit(runBootstrap(portalRoot()));
    }
    err(`Unknown command: ${first}`);
    printHelp();
    process.exit(1);
  } finally {
    rl.close();
  }
}

main().catch((e) => {
  err(e.stack || e.message);
  process.exit(1);
});
