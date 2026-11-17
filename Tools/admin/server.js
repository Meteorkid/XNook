/**
 * XNook 授权管理后台
 *
 * 单文件、零依赖（仅用 Node 内置模块）。启动方式：
 *
 *   XNOOK_ADMIN_TOKEN=$(openssl rand -hex 32) node Tools/admin/server.js
 *
 * 环境变量：
 *   XNOOK_ADMIN_TOKEN  管理接口令牌。**必须设置**，否则服务拒绝启动。
 *   XNOOK_PRIVATE_KEY  私钥文件路径（默认 ./license-private.key）
 *   XNOOK_PORT         监听端口（默认 8787）
 *   XNOOK_DATA_DIR     数据目录（默认 ./data）
 *
 * ## 两个角色
 *
 * 1. **管理接口**（`/api/admin/*`）：生成邀请码、查询台账、标记售出。
 *    需要 Bearer 令牌。
 *
 * 2. **登记接口**（`/api/activate`）：App 首次激活时上报一次。
 *    公开访问，仅记录，不影响 App 是否放行。
 *
 * ## 安全边界
 *
 * - 私钥只在本进程内存中使用，不通过任何接口返回。
 * - 管理接口必须携带令牌；令牌比较使用常量时间算法，避免时序侧信道。
 * - 登记接口做了限速，防止被灌库。
 */

'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

// ─────────────────────────────────────────────────────────────
// 配置
// ─────────────────────────────────────────────────────────────

const PORT = Number(process.env.XNOOK_PORT || 8787);
const ADMIN_TOKEN = process.env.XNOOK_ADMIN_TOKEN || '';
const PRIVATE_KEY_PATH = process.env.XNOOK_PRIVATE_KEY || path.join(__dirname, 'license-private.key');
const DATA_DIR = process.env.XNOOK_DATA_DIR || path.join(__dirname, 'data');
const LEDGER_PATH = path.join(DATA_DIR, 'ledger.json');
const REGISTRATIONS_PATH = path.join(DATA_DIR, 'registrations.jsonl');

if (!ADMIN_TOKEN) {
  console.error('错误：必须设置 XNOOK_ADMIN_TOKEN 环境变量。');
  console.error('');
  console.error('  例如：XNOOK_ADMIN_TOKEN=$(openssl rand -hex 32) node Tools/admin/server.js');
  console.error('');
  console.error('切勿使用空令牌或不设令牌启动——那等于把发码权限公开。');
  process.exit(1);
}

if (ADMIN_TOKEN.length < 16) {
  console.error('错误：XNOOK_ADMIN_TOKEN 太短（至少 16 字符）。');
  process.exit(1);
}

// ─────────────────────────────────────────────────────────────
// Crockford Base32（与 Swift 侧实现保持位序一致）
// ─────────────────────────────────────────────────────────────

const ALPHABET = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

function base32Encode(bytes) {
  let bits = '';
  for (const b of bytes) bits += b.toString(2).padStart(8, '0');
  const pad = (5 - (bits.length % 5)) % 5;
  bits += '0'.repeat(pad);
  let out = '';
  for (let i = 0; i < bits.length; i += 5) {
    out += ALPHABET[parseInt(bits.slice(i, i + 5), 2)];
  }
  return out;
}

function base32Decode(str) {
  const clean = str.toUpperCase().split('').filter((c) => ALPHABET.includes(c));
  let bits = '';
  for (const c of clean) bits += ALPHABET.indexOf(c).toString(2).padStart(5, '0');
  const nbytes = Math.floor(bits.length / 8);
  const out = Buffer.alloc(nbytes);
  for (let i = 0; i < nbytes; i++) {
    out[i] = parseInt(bits.slice(i * 8, i * 8 + 8), 2);
  }
  return out;
}

// ─────────────────────────────────────────────────────────────
// 载荷构造
// ─────────────────────────────────────────────────────────────

const DOMAIN_SEPARATOR = Buffer.from('XNook-License-v1', 'utf8');
const PREFIX = 'XNK1';
const GROUP_SIZE = 4;

/**
 * 构造 6 字节载荷。
 * 布局：版本(1) + 序列号(4, 大端) + 标志位(1)
 */
function buildPayload(serial, flags) {
  const buf = Buffer.alloc(6);
  buf[0] = 1;
  buf.writeUInt32BE(serial >>> 0, 1);
  buf[5] = flags;
  return buf;
}

/**
 * 用私钥签发邀请码。
 *
 * Node 的 crypto.sign(null, data, key) 对 Ed25519 使用 null 摘要算法，
 * 这正是 Ed25519 的正确用法（Ed25519 内部自带哈希）。
 */
function issueCode(privateKeyObject, serial, flags) {
  const payload = buildPayload(serial, flags);
  const message = Buffer.concat([DOMAIN_SEPARATOR, payload]);
  const signature = crypto.sign(null, message, privateKeyObject);

  const full = Buffer.concat([payload, signature]); // 6 + 64 = 70 字节
  const body = base32Encode(full);

  const groups = [];
  for (let i = 0; i < body.length; i += GROUP_SIZE) {
    groups.push(body.slice(i, i + GROUP_SIZE));
  }
  return {
    code: `${PREFIX}-${groups.join('-')}`,
    compact: `${PREFIX}${body}`,
    shortId: `XN-${String(serial).padStart(6, '0')}`,
    serial,
    flags,
  };
}

// ─────────────────────────────────────────────────────────────
// 私钥载入
// ─────────────────────────────────────────────────────────────

function loadPrivateKey() {
  if (!fs.existsSync(PRIVATE_KEY_PATH)) {
    console.error(`错误：找不到私钥文件：${PRIVATE_KEY_PATH}`);
    console.error('请先用 licensegen keygen 生成，或通过 XNOOK_PRIVATE_KEY 指定路径。');
    process.exit(1);
  }
  const content = fs.readFileSync(PRIVATE_KEY_PATH, 'utf8');
  const line = content
    .split('\n')
    .map((l) => l.trim())
    .find((l) => l && !l.startsWith('#'));

  if (!line) {
    console.error('错误：私钥文件为空或不含有效内容。');
    process.exit(1);
  }

  const raw = Buffer.from(line, 'base64');
  if (raw.length !== 32) {
    console.error(`错误：私钥应为 32 字节，实际 ${raw.length} 字节。`);
    process.exit(1);
  }

  // 从 32 字节种子构造 PKCS#8 DER，供 Node 使用
  const pkcs8 = Buffer.concat([
    Buffer.from('302e020100300506032b657004220420', 'hex'),
    raw,
  ]);

  return crypto.createPrivateKey({ key: pkcs8, format: 'der', type: 'pkcs8' });
}

let privateKeyObject;
try {
  privateKeyObject = loadPrivateKey();
} catch (error) {
  console.error('错误：私钥载入失败：', error.message);
  process.exit(1);
}

// 计算公钥指纹，用于自检与展示（便于核对 App 内嵌的公钥是否一致）
const publicKeyObject = crypto.createPublicKey(privateKeyObject);
const publicKeyDer = publicKeyObject.export({ format: 'der', type: 'spki' });
const publicKeyRaw = publicKeyDer.subarray(publicKeyDer.length - 32);
const publicKeyBase64 = publicKeyRaw.toString('base64');
const keyFingerprint = crypto
  .createHash('sha256')
  .update(publicKeyRaw)
  .digest('hex')
  .slice(0, 16);

// ─────────────────────────────────────────────────────────────
// 台账持久化
// ─────────────────────────────────────────────────────────────

function ensureDataDir() {
  if (!fs.existsSync(DATA_DIR)) fs.mkdirSync(DATA_DIR, { recursive: true });
}

function loadLedger() {
  ensureDataDir();
  if (!fs.existsSync(LEDGER_PATH)) {
    return { nextSerial: 1, batches: [], codes: {} };
  }
  try {
    return JSON.parse(fs.readFileSync(LEDGER_PATH, 'utf8'));
  } catch {
    console.error('警告：台账文件损坏，已备份并重建。');
    fs.renameSync(LEDGER_PATH, `${LEDGER_PATH}.corrupt-${Date.now()}`);
    return { nextSerial: 1, batches: [], codes: {} };
  }
}

function saveLedger(ledger) {
  ensureDataDir();
  // 先写临时文件再原子替换，避免写入中途崩溃导致台账损坏
  const tmp = `${LEDGER_PATH}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(ledger, null, 2), 'utf8');
  fs.renameSync(tmp, LEDGER_PATH);
}

function appendRegistration(record) {
  ensureDataDir();
  fs.appendFileSync(REGISTRATIONS_PATH, JSON.stringify(record) + '\n', 'utf8');
}

function loadRegistrations() {
  if (!fs.existsSync(REGISTRATIONS_PATH)) return [];
  return fs
    .readFileSync(REGISTRATIONS_PATH, 'utf8')
    .split('\n')
    .filter(Boolean)
    .map((line) => {
      try { return JSON.parse(line); } catch { return null; }
    })
    .filter(Boolean);
}

// ─────────────────────────────────────────────────────────────
// HTTP 辅助
// ─────────────────────────────────────────────────────────────

function sendJSON(res, status, payload) {
  const body = JSON.stringify(payload);
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(body),
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
  });
  res.end(body);
}

/**
 * 常量时间令牌比较。
 * 直接字符串比较会在首个不同字符处提前返回，泄露令牌前缀信息。
 */
function safeTokenEquals(a, b) {
  const bufA = Buffer.from(String(a), 'utf8');
  const bufB = Buffer.from(String(b), 'utf8');
  if (bufA.length !== bufB.length) {
    // 长度不同也要消耗相近时间，避免通过响应时间判断长度
    crypto.timingSafeEqual(bufA, bufA);
    return false;
  }
  return crypto.timingSafeEqual(bufA, bufB);
}

function isAuthorized(req) {
  const header = req.headers['authorization'] || '';
  if (!header.startsWith('Bearer ')) return false;
  return safeTokenEquals(header.slice(7), ADMIN_TOKEN);
}

function readBody(req, limitBytes = 64 * 1024) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > limitBytes) {
        reject(new Error('请求体过大'));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

// 登记接口限速：每个 IP 每分钟最多 20 次
const rateBuckets = new Map();
function rateLimited(ip) {
  const now = Date.now();
  const bucket = rateBuckets.get(ip) || [];
  const recent = bucket.filter((t) => now - t < 60_000);
  recent.push(now);
  rateBuckets.set(ip, recent);
  return recent.length > 20;
}

// ─────────────────────────────────────────────────────────────
// 路由
// ─────────────────────────────────────────────────────────────

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
  const pathname = url.pathname;

  // ── 公开：App 激活登记 ──
  if (pathname === '/api/activate' && req.method === 'POST') {
    const ip = req.socket.remoteAddress || 'unknown';
    if (rateLimited(ip)) {
      return sendJSON(res, 429, { ok: false, error: 'too many requests' });
    }
    try {
      const body = JSON.parse((await readBody(req)) || '{}');
      const serial = Number(body.serial);
      if (!Number.isInteger(serial) || serial < 0) {
        return sendJSON(res, 400, { ok: false, error: 'invalid serial' });
      }

      // 查台账：如果这个序列号是本站签发的，记下它已被激活
      const ledger = loadLedger();
      const known = ledger.codes[String(serial)];
      if (known && !known.activatedAt) {
        known.activatedAt = new Date().toISOString();
        known.activatedPlatform = String(body.platform || 'unknown').slice(0, 32);
        known.activatedVersion = String(body.appVersion || 'unknown').slice(0, 32);
        saveLedger(ledger);
      }

      appendRegistration({
        serial,
        shortId: String(body.shortId || '').slice(0, 32),
        platform: String(body.platform || 'unknown').slice(0, 32),
        appVersion: String(body.appVersion || 'unknown').slice(0, 32),
        knownIssued: Boolean(known),
        at: new Date().toISOString(),
      });

      // 登记只是记录，永远返回 ok —— 是否放行由 App 本地决定
      return sendJSON(res, 200, { ok: true, recorded: true, knownIssued: Boolean(known) });
    } catch (error) {
      return sendJSON(res, 400, { ok: false, error: 'bad request' });
    }
  }

  // ── 以下均需管理员令牌 ──
  if (pathname.startsWith('/api/admin/')) {
    if (!isAuthorized(req)) {
      return sendJSON(res, 401, { ok: false, error: 'unauthorized' });
    }

    // 公钥信息（供核对 App 内嵌公钥）
    if (pathname === '/api/admin/pubkey' && req.method === 'GET') {
      return sendJSON(res, 200, {
        ok: true,
        publicKeyBase64: publicKeyBase64,
        fingerprint: keyFingerprint,
      });
    }

    // 台账总览
    if (pathname === '/api/admin/ledger' && req.method === 'GET') {
      const ledger = loadLedger();
      const all = Object.values(ledger.codes);
      return sendJSON(res, 200, {
        ok: true,
        nextSerial: ledger.nextSerial,
        total: all.length,
        sold: all.filter((c) => c.sold).length,
        activated: all.filter((c) => c.activatedAt).length,
        batches: ledger.batches,
      });
    }

    // 生成邀请码
    if (pathname === '/api/admin/issue' && req.method === 'POST') {
      try {
        const body = JSON.parse((await readBody(req)) || '{}');
        const count = Math.min(Math.max(Number(body.count) || 1, 1), 1000);
        const note = String(body.note || '').slice(0, 120);

        let flags = 1; // perpetual
        if (body.earlySupporter) flags |= 2;
        if (body.complimentary) flags |= 4;

        const ledger = loadLedger();
        const issued = [];
        const batchId = `batch-${Date.now().toString(36)}`;

        for (let i = 0; i < count; i++) {
          const serial = ledger.nextSerial++;
          const result = issueCode(privateKeyObject, serial, flags);
          ledger.codes[String(serial)] = {
            serial,
            code: result.code,
            compact: result.compact,
            shortId: result.shortId,
            flags,
            batchId,
            note,
            issuedAt: new Date().toISOString(),
            sold: false,
            activatedAt: null,
          };
          issued.push(result);
        }

        ledger.batches.push({
          id: batchId,
          count,
          note,
          flags,
          createdAt: new Date().toISOString(),
          serialRange: [issued[0].serial, issued[issued.length - 1].serial],
        });
        saveLedger(ledger);

        return sendJSON(res, 200, { ok: true, batchId, codes: issued });
      } catch (error) {
        return sendJSON(res, 400, { ok: false, error: error.message });
      }
    }

    // 标记已售出（记录发卡网/手动销售情况）
    if (pathname === '/api/admin/mark-sold' && req.method === 'POST') {
      try {
        const body = JSON.parse((await readBody(req)) || '{}');
        const serials = Array.isArray(body.serials) ? body.serials : [];
        const ledger = loadLedger();
        let updated = 0;
        for (const s of serials) {
          const entry = ledger.codes[String(s)];
          if (entry) {
            entry.sold = true;
            entry.soldAt = new Date().toISOString();
            entry.soldNote = String(body.note || '').slice(0, 120);
            updated++;
          }
        }
        saveLedger(ledger);
        return sendJSON(res, 200, { ok: true, updated });
      } catch (error) {
        return sendJSON(res, 400, { ok: false, error: error.message });
      }
    }

    // 查询单个邀请码
    if (pathname === '/api/admin/lookup' && req.method === 'GET') {
      const serial = Number(url.searchParams.get('serial'));
      const ledger = loadLedger();
      const entry = ledger.codes[String(serial)];
      if (!entry) return sendJSON(res, 404, { ok: false, error: 'not found' });
      return sendJSON(res, 200, { ok: true, entry });
    }

    // 导出指定批次的 CSV
    if (pathname === '/api/admin/export' && req.method === 'GET') {
      const batchId = url.searchParams.get('batch');
      const ledger = loadLedger();
      const rows = Object.values(ledger.codes)
        .filter((c) => !batchId || c.batchId === batchId)
        .sort((a, b) => a.serial - b.serial);

      const csv = ['serial,code,short_id,flags,sold,activated_at']
        .concat(rows.map((c) =>
          [c.serial, c.code, c.shortId, c.flags, c.sold, c.activatedAt || ''].join(',')
        ))
        .join('\n') + '\n';

      res.writeHead(200, {
        'Content-Type': 'text/csv; charset=utf-8',
        'Content-Disposition': `attachment; filename="xnook-${batchId || 'all'}.csv"`,
      });
      return res.end(csv);
    }

    // 登记记录
    if (pathname === '/api/admin/registrations' && req.method === 'GET') {
      const records = loadRegistrations();
      return sendJSON(res, 200, { ok: true, count: records.length, records: records.slice(-200) });
    }

    return sendJSON(res, 404, { ok: false, error: 'unknown admin endpoint' });
  }

  // ── 静态页面 ──
  if (pathname === '/' || pathname === '/index.html') {
    const html = fs.readFileSync(path.join(__dirname, 'index.html'), 'utf8');
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    return res.end(html);
  }

  sendJSON(res, 404, { ok: false, error: 'not found' });
});

server.listen(PORT, '127.0.0.1', () => {
  console.log('');
  console.log('  XNook 授权管理后台已启动');
  console.log('');
  console.log(`  地址：      http://127.0.0.1:${PORT}`);
  console.log(`  私钥：      ${PRIVATE_KEY_PATH}`);
  console.log(`  数据目录：  ${DATA_DIR}`);
  console.log(`  公钥指纹：  ${keyFingerprint}`);
  console.log('');
  console.log('  公钥（Base64，应与 App 内嵌值一致）：');
  console.log(`    ${publicKeyBase64}`);
  console.log('');
  console.log('  仅监听 127.0.0.1，外部无法访问。如需公网部署，请置于 HTTPS 反向代理之后。');
  console.log('');
});
