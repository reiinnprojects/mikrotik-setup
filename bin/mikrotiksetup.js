#!/usr/bin/env node

/**
 * mikrotiksetup — onboard a LokalFi MikroTik from the NUC terminal.
 * Calls lokalfi-captive-portal npm scripts. Gold backups live in this repo.
 */

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
    err(`Gold backup missing: ${f}`);
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
    warn(`deployment/docker/.env management IP is ${ip}, gold LAN is ${GOLD_LAN}.`);
  }
  if (pass && pass !== GOLD_CREDS.password) {
    warn('deployment/docker/.env MikroTik password is not lokalfi.net. App API may miss this router.');
  }
  if (user && user !== GOLD_CREDS.user) {
    warn(`deployment/docker/.env MikroTik user is ${user}, gold is admin.`);
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

function runNpm(root, script, extra = [], extraEnv = {}) {
  info(`npm run ${script}${extra.length ? ' -- ' + extra.join(' ') : ''}`);
  const r = spawnSync('npm', ['run', script, '--', ...extra], {
    cwd: root,
    stdio: 'inherit',
    env: { ...process.env, ...extraEnv },
  });
  return r.status || 0;
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
  console.log(`mikrotiksetup — LokalFi MikroTik onboarder

Usage:
  mikrotiksetup                 interactive menu (Enter = everything)
  mikrotiksetup setup           full 09-17 gold onboard
  mikrotiksetup config          set path to lokalfi-captive-portal
  mikrotiksetup upload-hotspot
  mikrotiksetup wan
  mikrotiksetup device-mode
  mikrotiksetup apply-portal-network
  mikrotiksetup pull-backup
  mikrotiksetup restore
  mikrotiksetup format-sd
  mikrotiksetup bootstrap

Factory routers listen on 192.168.88.1. A NUC that is only 192.168.10.220 cannot reach that
until you are on the same LAN (or add 192.168.88.x yourself). After restore: 192.168.10.1
on ether2-LAN, admin / lokalfi.net. Device-mode still needs a short reset tap on the box.

Gold backups are 09-17 (July voucher set). Lab serial ${LAB_SERIAL} is blocked unless --force.
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
  warn('If the IP is 192.168.88.1, this NUC must already be on that subnet.');
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
    warn('Could not set admin password. Restore may still apply gold credentials.');
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
  return runNpm(root, 'docker:bootstrap-mikrotik');
}

async function cmdSetup(rl, forceRestore) {
  const root = portalRoot();
  warnEnvMismatch(root);
  const sess = await probeSession(rl);
  const model = requireModel(sess);
  info(`Model ${model} serial ${sess.rb.serial || '?'}`);

  const env = mikrotikEnv(sess);
  if (runNpm(root, 'mikrotik:enable-hotspot-device-mode', [], env) !== 0) {
    warn('Device-mode CLI finished with an error. Tap reset or power-cycle if the router asked for it, then continue.');
  }

  const restoreArgs = ['--file', goldFile(model), '--wait', sess.host];
  if (forceRestore || sess.rb.serial === LAB_SERIAL) {
    if (sess.rb.serial === LAB_SERIAL && !forceRestore) {
      err(`Refusing lab serial ${LAB_SERIAL}. Re-run with: mikrotiksetup restore --force`);
      process.exit(1);
    }
    restoreArgs.splice(2, 0, '--force');
  }
  if (runNpm(root, 'mikrotik:restore-backup', restoreArgs, env) !== 0) {
    process.exit(1);
  }

  const after = {
    host: GOLD_LAN,
    user: GOLD_CREDS.user,
    password: GOLD_CREDS.password,
  };
  const rbOut = sshOk(after.host, after.user, after.password, '/system routerboard print');
  if (!rbOut) {
    err(`No SSH on ${GOLD_LAN} after restore. Plug the NUC into ether2-LAN on 192.168.10.0/24.`);
    process.exit(1);
  }
  after.rb = parseRouterboard(rbOut);
  const afterModel = requireModel(after);
  if (afterModel !== model) {
    err(`Model changed after restore (${model} → ${afterModel}). Stop.`);
    process.exit(1);
  }

  info('Re-checking device-mode hotspot=yes ...');
  runNpm(root, 'mikrotik:enable-hotspot-device-mode', ['--verify-only'], mikrotikEnv(after));

  const afterEnv = mikrotikEnv(after);
  if (afterModel === 'RB750Gr3') {
    if (runNpm(root, 'mikrotik:fix-wan-internet', [], afterEnv) !== 0) {
      warn('WAN parity returned non-zero.');
    }
    const probe = spawnSync('npm', ['run', 'mikrotik:format-sd', '--', '--probe', after.host], {
      cwd: root,
      encoding: 'utf8',
      env: { ...process.env, ...afterEnv },
    });
    if (probe.status === 2) {
      err('No SD card. Insert a card and run: mikrotiksetup format-sd  then  mikrotiksetup upload-hotspot');
      process.exit(1);
    }
    if (probe.status === 3) {
      err('More than one removable disk. Unplug extras or: mikrotiksetup format-sd  (it will ask for --slot)');
      process.exit(1);
    }
    if (runNpm(root, 'mikrotik:format-sd', ['--yes', after.host], afterEnv) !== 0) {
      process.exit(1);
    }
    if (runNpm(root, 'mikrotik:upload-hotspot', [after.host], { ...afterEnv, MIKROTIK_REQUIRE_REMOVABLE: 'true' }) !== 0) {
      process.exit(1);
    }
  } else {
    if (runNpm(root, 'mikrotik:upload-hotspot', [after.host], { ...afterEnv, MIKROTIK_ROUTER_FILES_DISK: 'flash' }) !== 0) {
      process.exit(1);
    }
  }

  const lan = nucLanIp(root);
  if (runNpm(root, 'mikrotik:apply-portal-network', [after.host], { ...afterEnv, NUC_LAN_IP: lan }) !== 0) {
    process.exit(1);
  }

  runBootstrap(root);
  ok(`Done. ${afterModel} html on the router. Guest portal: http://lokalfi.net/login.html`);
}

async function cmdRestore(rl, force) {
  const root = portalRoot();
  const sess = await probeSession(rl);
  const model = requireModel(sess);
  const args = ['--file', goldFile(model), sess.host];
  if (force) args.splice(2, 0, '--force');
  process.exit(runNpm(root, 'mikrotik:restore-backup', args, mikrotikEnv(sess)));
}

async function cmdFormat(rl) {
  const root = portalRoot();
  const sess = await probeSession(rl);
  process.exit(runNpm(root, 'mikrotik:format-sd', [sess.host], mikrotikEnv(sess)));
}

async function wrap(script, extra = [], extraEnv = {}) {
  const root = portalRoot();
  const host = process.env.MIKROTIK_HOST || GOLD_LAN;
  const env = {
    MIKROTIK_HOST: host,
    MIKROTIK_USER: process.env.MIKROTIK_USER || GOLD_CREDS.user,
    MIKROTIK_PASSWORD: process.env.MIKROTIK_PASSWORD || GOLD_CREDS.password,
    ...extraEnv,
  };
  process.exit(runNpm(root, script, extra.length ? extra : [host], env));
}

async function menu(rl) {
  console.log('');
  info('What do you want to run?');
  console.log('  1) Everything (09-17 gold onboard)');
  console.log('  2) Upload hotspot');
  console.log('  3) Router WAN / parity');
  console.log('  4) Enable hotspot device-mode');
  console.log('  5) Apply portal network');
  console.log('  6) Pull backup (lab dump)');
  console.log('  7) Restore 09-17 gold');
  console.log('  8) Format SD (exFAT, RB750)');
  console.log('  9) Bootstrap app MikroTik config');
  const choice = await prompt(rl, 'Choice', '1');
  switch (choice) {
    case '1':
      await cmdSetup(rl, false);
      break;
    case '2':
      await wrap('mikrotik:upload-hotspot');
      break;
    case '3':
      await wrap('mikrotik:router-parity-fix');
      break;
    case '4':
      await wrap('mikrotik:enable-hotspot-device-mode');
      break;
    case '5':
      await wrap('mikrotik:apply-portal-network', [], { NUC_LAN_IP: nucLanIp(portalRoot()) });
      break;
    case '6':
      await wrap('mikrotik:pull-backup');
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
  const argv = raw.filter((a) => a !== '--force');
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
      await cmdSetup(rl, force);
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
      await wrap('mikrotik:upload-hotspot');
      return;
    }
    if (first === 'wan' || first === 'router-parity-fix') {
      await wrap('mikrotik:router-parity-fix');
      return;
    }
    if (first === 'device-mode') {
      await wrap('mikrotik:enable-hotspot-device-mode');
      return;
    }
    if (first === 'apply-portal-network') {
      await wrap('mikrotik:apply-portal-network', [], { NUC_LAN_IP: nucLanIp(portalRoot()) });
      return;
    }
    if (first === 'pull-backup') {
      await wrap('mikrotik:pull-backup');
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
