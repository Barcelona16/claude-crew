#!/usr/bin/env node
// crew-keyresolve.js — single source of truth for a crew session's EFFECTIVE model + key.
//
// Why it exists: /model and the stdin session JSON only expose a generic tier name
// ("Opus 4.8") — they never reveal which backend a request actually routes to, nor which
// api-key it uses. Both crew-statusline.sh (renders "⬡ <sess> · <model> · 🔑<key>") and
// `crew ls` (KEY column) need that resolved truth. This module is the one place that logic
// lives, so the two callers can never drift apart.
//
// Output: "<model>\t<key>" on stdout, single line, no trailing newline. Never throws;
// prints "?" for a field it cannot resolve. Meant to be fast (~one node startup).
//
// Inputs (all optional):
//   argv[2]                    session name -> read <state>/<name>.backend and .key
//   CREW_MODEL / CREW_BACKEND  override the model (else <name>.backend, else CCR Router.default)
//   CREW_KEY                   explicit key pin ("-" or "" = no pin)
//   ANTHROPIC_BASE_URL         routing mode. If empty (the `crew ls` case, which has no per-
//                              session live env), it is DERIVED from the model's backend conf,
//                              then defaults to the crew-proxy (:8788) — the crew standard.
//   CREW_STATE                 state dir (default ~/.local/share/claude-crew)
//   CREW_HOME                  config dir (default ~/.config/claude-crew)
//
// Key resolution (mirrors the routing crew-proxy / CCR actually perform):
//   explicit pin wins; else by routing mode —
//     :8788 crew-proxy  -> key-policy.conf primary alias for the model (ambient token is just
//                          the entry credential, not the real upstream key)
//     :3456 CCR direct  -> the model's provider api_key in CCR config -> alias
//     direct gateway    -> ambient ANTHROPIC_AUTH_TOKEN itself is the real key -> alias
//
// Secrets: reads keys.conf only to build a token->alias map; never prints a full token
// (unknown tokens are masked as "abcd…xyz"), same as the old inline statusline logic.

var fs = require("fs");
var HOME = process.env.HOME || "";
var STATE = process.env.CREW_STATE || (HOME + "/.local/share/claude-crew");
var CONF = process.env.CREW_HOME || (HOME + "/.config/claude-crew");
var sess = process.argv[2] || process.env.CREW_SESSION || process.env.SESS || "";

function rd(p) { try { return fs.readFileSync(p, "utf8"); } catch (e) { return ""; } }

// keys.conf: "<alias>=<token>" (or legacy space form "<alias> <token>") -> token->alias
var tok2alias = {};
(function () {
  var kl = rd(CONF + "/keys.conf").split("\n"), i, ln, eqk, ka, kt, parts;
  for (i = 0; i < kl.length; i++) {
    ln = kl[i].trim(); if (!ln || ln[0] === "#") continue;
    eqk = ln.indexOf("=");
    if (eqk >= 0) { ka = ln.slice(0, eqk).trim(); kt = ln.slice(eqk + 1).trim(); if (ka && kt) tok2alias[kt] = ka; }
    else { parts = ln.split(/\s+/); if (parts.length >= 2) tok2alias[parts[1]] = parts[0]; }
  }
})();

// key-policy.conf: "<model> = <alias1> <alias2> ..." (high->low priority)
var policy = {};
(function () {
  var pl = rd(CONF + "/key-policy.conf").split("\n"), i, ln, eq, mk, al;
  for (i = 0; i < pl.length; i++) {
    ln = pl[i].trim(); if (!ln || ln[0] === "#") continue;
    eq = ln.indexOf("="); if (eq < 0) continue;
    mk = ln.slice(0, eq).trim(); al = ln.slice(eq + 1).trim().split(/\s+/); policy[mk] = al;
  }
})();

// CCR 3 provider map. CCR itself stores the live config in SQLite, while crew
// keeps this private JSON map for deterministic key/model resolution.
var ccr = {}; try { ccr = JSON.parse(rd(process.env.CREW_CCR_CONFIG || (CONF + "/ccr-providers.json"))); } catch (e) {}
var provs = ccr.Providers || ccr.providers || [];
function provKey(n) { for (var j = 0; j < provs.length; j++) { if (provs[j] && provs[j].name === n) return (provs[j].api_key || provs[j].apiKey || "") + ""; } return ""; }
var rdef = ((ccr.Router && ccr.Router.default) || "") + "", dprov = rdef, dmodel = rdef, ci = rdef.indexOf("/");
if (ci >= 0) { dprov = rdef.slice(0, ci); dmodel = rdef.slice(ci + 1); }
if (!dmodel && provs[0]) {
  dprov = (provs[0].name || "") + "";
  dmodel = ((provs[0].models || [])[0] || "") + "";
}

// A model's backend conf tells us its BASE_URL (routing mode) when there is no live env.
// Match by realmodel against each backends/*.conf MODEL ("provider/realmodel" or "realmodel").
// Returns { base, prov } — prov is the provider prefix when the conf carries one
// ("joycode-oai/Kimi-K3" -> "joycode-oai"), so a policy-less model can still resolve the
// key its CCR provider actually uses (crew-proxy passthrough rides that provider's key).
function deriveBaseFromBackends(rm) {
  var out = { base: "", prov: "", model: "" };
  if (!rm || rm === "?") return out;
  try {
    var dir = CONF + "/backends", files, i, txt, m, mm, c, bu;
    // The session's .backend / CREW_MODEL value may be a backend NAME ("kimi-k3") whose
    // realmodel ("Kimi-K3") differs in case — an exact-name file beats the realmodel scan.
    txt = rd(dir + "/" + rm + ".conf");
    if (txt) {
      m = /(^|\n)[ \t]*MODEL[ \t]*=[ \t]*([^\n]+)/.exec(txt);
      if (m) {
        mm = m[2].trim(); c = mm.indexOf("/");
        if (c >= 0) { out.prov = mm.slice(0, c).trim(); mm = mm.slice(c + 1); }
        // The conf's real model segment — lets callers replace a backend NAME (opus47)
        // with the model it actually routes to (Claude-Opus-4.7-joybuilder) for display.
        out.model = mm.trim();
        out.base = ((/(^|\n)[ \t]*BASE_URL[ \t]*=[ \t]*([^\n]+)/.exec(txt) || [])[2] || "").trim();
        if (out.prov || out.base || out.model) return out;
      }
    }
    files = fs.readdirSync(dir);
    for (i = 0; i < files.length; i++) {
      if (!/\.conf$/.test(files[i])) continue;
      txt = rd(dir + "/" + files[i]);
      m = /(^|\n)[ \t]*MODEL[ \t]*=[ \t]*([^\n]+)/.exec(txt); if (!m) continue;
      mm = m[2].trim(); c = mm.indexOf("/");
      if (c >= 0) { out.prov = mm.slice(0, c).trim(); mm = mm.slice(c + 1); }
      if (mm.trim() !== rm) { out.prov = ""; continue; }
      out.model = mm.trim();
      bu = /(^|\n)[ \t]*BASE_URL[ \t]*=[ \t]*([^\n]+)/.exec(txt);
      out.base = bu ? bu[2].trim() : "";
      return out;
    }
  } catch (e) {}
  return out;
}

// ---- resolve one session's EFFECTIVE {model, key} ----
// opts: { backend, key, base } — explicit overrides. Single-session mode fills them from the
// live process env (CREW_MODEL/CREW_KEY/ANTHROPIC_BASE_URL — statusline runs inside the claude
// process, so its env IS the truth). Batch mode passes backend explicitly (the real model crew
// ls scraped from /proc) and leaves key/base empty (no per-session live env in a batch call),
// so key is derived structurally. keys/policy/ccr are module-level (parsed once, reused here).
function resolveOne(sess, opts) {
  opts = opts || {};
  // ---- model ----
  var model = opts.backend || "";
  if (!model && sess) model = rd(STATE + "/" + sess + ".backend").trim();
  if (model === "" || model === "-" || model === "default") model = dmodel;   // ambient plain -> concrete
  var mprov = ""; var mi = model.indexOf("/"); if (mi >= 0) { mprov = model.slice(0, mi); model = model.slice(mi + 1); }
  var realmodel = model;

  // ---- routing mode: live ANTHROPIC_BASE_URL wins; else derive from conf; else proxy default ----
  var base = opts.base || "";
  // Always resolve the backend conf: even when live env gives us the base, the model value may be
  // a backend NAME ("opus47") — the conf tells us the real model it routes to for display.
  var bconf = deriveBaseFromBackends(realmodel);
  // If model was a backend NAME whose conf carries a different real model segment, show the real
  // one (opus47 -> Claude-Opus-4.7-joybuilder). Also adopt its provider prefix for key derivation.
  if (bconf.model && bconf.model !== realmodel) {
    realmodel = bconf.model; model = bconf.model;
    if (!mprov && bconf.prov) mprov = bconf.prov;
  }
  if (!base) base = bconf.base;
  var isProxy = /:8788/.test(base), isCCR = /:3456/.test(base);
  if (!base && !isProxy && !isCCR) isProxy = true;   // crew standard: all backends route via :8788

  // ---- key ----
  var key = opts.key || "";
  if ((!key || key === "-") && sess) key = rd(STATE + "/" + sess + ".key").trim();
  if (key === "-") key = "";
  if (!key) {
    if (isProxy) {
      var mname = realmodel || dmodel;
      var pol = policy[mname] || null;
      if (pol && pol.length) key = pol[0];
      // No policy line for this model -> crew-proxy passes it through to CCR, where the
      // provider named in the backend conf (or the CCR model string) supplies the real key.
      // Derive THAT — never fall back to policy[CREW_BACKEND]: that ambient env var leaks in
      // from whatever crew session ran `crew ls` and would mislabel unrelated sessions
      // (e.g. a joycode-keyed session displaying "personal").
      if (!key) {
        var pprov = mprov || bconf.prov || dprov, ptok = provKey(pprov) || provKey(dprov);
        if (ptok) key = tok2alias[ptok] || (ptok.length > 10 ? (ptok.slice(0, 4) + "…" + ptok.slice(-3)) : ptok);
      }
    } else if (isCCR) {
      var prov = mprov || dprov, tok = provKey(prov) || provKey(dprov);
      if (tok) key = tok2alias[tok] || (tok.length > 10 ? (tok.slice(0, 4) + "…" + tok.slice(-3)) : tok);
    } else {
      var at = opts.authToken || "";
      if (at) key = tok2alias[at] || (at.length > 10 ? (at.slice(0, 4) + "…" + at.slice(-3)) : at);
    }
  }
  if (!model) model = "?";
  if (!key) key = "?";
  return { model: model, key: key };
}

// ---- entry: single-session (statusline/compat) vs --batch (crew ls: one node for all) ----
if (process.argv[2] === "--batch") {
  // stdin: lines "name\tbackend" (backend = real model crew ls scraped, may be empty).
  // stdout: lines "name\tmodel\tkey". One node process resolves every session (files read once).
  var input = "";
  try { input = fs.readFileSync(0, "utf8"); } catch (e) { input = ""; }
  var lines = input.split("\n"), out = [];
  for (var li = 0; li < lines.length; li++) {
    var ln = lines[li]; if (!ln) continue;
    var tab = ln.indexOf("\t");
    var nm = tab >= 0 ? ln.slice(0, tab) : ln;
    var bk = tab >= 0 ? ln.slice(tab + 1) : "";
    if (!nm) continue;
    var r = resolveOne(nm, { backend: bk });   // batch: no live env, key derived structurally
    out.push(nm + "\t" + r.model + "\t" + r.key);
  }
  process.stdout.write(out.join("\n"));
} else {
  // Single session: env is the live truth (statusline runs inside the claude process).
  var r1 = resolveOne(sess, {
    backend: process.env.CREW_MODEL || process.env.CREW_BACKEND || "",
    key: process.env.CREW_KEY || "",
    base: process.env.ANTHROPIC_BASE_URL || "",
    authToken: process.env.ANTHROPIC_AUTH_TOKEN || process.env.ANTHROPIC_API_KEY || "",
  });
  process.stdout.write(r1.model + "\t" + r1.key);
}
