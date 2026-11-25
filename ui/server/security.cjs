// Request-surface guards for the local API server.
// Kept out of index.cjs so the rules are assertable without starting a server
// that spawns admin-privileged PowerShell.

// Item ids come from generate-report.ps1's Set-Id: "<prefix>NNN" (3+ digits).
// confirmed-ids.json is the credential clean-residuals.ps1 deletes registry keys,
// services and PATH segments by, so nothing else may reach it.
const ITEM_ID_PATTERN = /^(?:fs|reg|svc|tsk|str|shl|path|uni)_\d{3,}$/;

function validateItemIds(value) {
  if (!Array.isArray(value)) {
    return { ok: false, error: 'ids must be an array' };
  }
  for (const id of value) {
    if (typeof id !== 'string' || !ITEM_ID_PATTERN.test(id)) {
      return { ok: false, error: 'ids contain unknown item ids' };
    }
  }
  return { ok: true, error: '' };
}

function splitHostname(hostHeader) {
  const raw = String(hostHeader || '');
  if (raw.startsWith('[')) {
    const end = raw.indexOf(']');
    return end === -1 ? raw : raw.slice(0, end + 1);
  }
  const colon = raw.lastIndexOf(':');
  return colon === -1 ? raw : raw.slice(0, colon);
}

function isIPv4Loopback(value) {
  const parts = value.split('.');
  return parts.length === 4
    && parts.every(part => /^\d{1,3}$/.test(part) && Number(part) <= 255);
}

function isLoopbackHostname(value) {
  const h = String(value || '').toLowerCase().replace(/^\[|\]$/g, '');
  return h === 'localhost' || h === '::1' || (h.startsWith('127.') && isIPv4Loopback(h));
}

function isAllowedHost(hostHeader, hostname, expectedHosts) {
  return isLoopbackHostname(hostname) || expectedHosts.has(hostHeader);
}

function isAllowedOrigin(origin, hostHeader, allowedOrigins) {
  return origin === `http://${hostHeader}` || allowedOrigins.has(origin);
}

// Binding to loopback is not an attacker barrier: any page the user opens can POST
// to http://127.0.0.1:<port>. The dev server proxies /api and production serves the
// SPA from this same origin, so no CORS is required — and wildcard CORS additionally
// let the cross-origin *response* be read. Everything without an Origin header
// (curl, local tooling) still passes; browser cross-origin requests are rejected.
// The Host check closes DNS rebinding, where the attacker's own domain resolves to
// 127.0.0.1 and Origin/Host would otherwise agree with each other.
function createOriginGuard({ allowedOrigins = [], expectedHosts = [] } = {}) {
  const allowed = new Set(allowedOrigins);
  const hosts = new Set(expectedHosts);
  return function originGuard(req, res, next) {
    const hostHeader = String(req.headers.host || '');
    const hostname = splitHostname(hostHeader);
    if (!isAllowedHost(hostHeader, hostname, hosts)) {
      res.status(403).json({ error: 'non-loopback host rejected' });
      return;
    }
    const origin = req.headers.origin;
    if (!origin) {
      next();
      return;
    }
    if (isAllowedOrigin(origin, hostHeader, allowed)) {
      next();
      return;
    }
    res.status(403).json({ error: 'cross-origin request rejected' });
  };
}

module.exports = {
  ITEM_ID_PATTERN,
  validateItemIds,
  isLoopbackHostname,
  splitHostname,
  createOriginGuard,
};
