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

// CCR config: providers + Router.default ("provider,model")
var ccr = {}; try { ccr = JSON.parse(rd(HOME + "/.claude-code-router/config.json")); } catch (e) {}
var provs = ccr.Providers || ccr.providers || [];
function provKey(n) { for (var j = 0; j < provs.length; j++) { if (provs[j] && provs[j].name === n) return (provs[j].api_key || provs[j].apiKey || "") + ""; } return ""; }
var rdef = ((ccr.Router && ccr.Router.default) || "") + "", dprov = rdef, dmodel = rdef, ci = rdef.indexOf(",");
if (ci >= 0) { dprov = rdef.slice(0, ci); dmodel = rdef.slice(ci + 1); }

// A model's backend conf tells us its BASE_URL (routing mode) when there is no live env.
// Match by realmodel against each backends/*.conf MODEL ("provider,realmodel" or "realmodel").
function deriveBaseFromBackends(rm) {
  if (!rm || rm === "?") return "";
  try {
    var dir = CONF + "/backends", files = fs.readdirSync(dir), i, txt, m, mm, c, bu;
    for (i = 0; i < files.length; i++) {
      if (!/\.conf$/.test(files[i])) continue;
      txt = rd(dir + "/" + files[i]);
      m = /(^|\n)[ \t]*MODEL[ \t]*=[ \t]*([^\n]+)/.exec(txt); if (!m) continue;
      mm = m[2].trim(); c = mm.indexOf(","); if (c >= 0) mm = mm.slice(c + 1);
      if (mm.trim() !== rm) continue;
      bu = /(^|\n)[ \t]*BASE_URL[ \t]*=[ \t]*([^\n]+)/.exec(txt);
      return bu ? bu[2].trim() : "";
    }
  } catch (e) {}
  return "";
}

// ---- model ----
var model = process.env.CREW_MODEL || process.env.CREW_BACKEND || "";
if (!model && sess) model = rd(STATE + "/" + sess + ".backend").trim();
if (model === "" || model === "-" || model === "default") model = dmodel;   // ambient plain -> concrete
var mprov = ""; var mi = model.indexOf(","); if (mi >= 0) { mprov = model.slice(0, mi); model = model.slice(mi + 1); }
var realmodel = model;

// ---- routing mode: live ANTHROPIC_BASE_URL wins; else derive from conf; else proxy default ----
var base = process.env.ANTHROPIC_BASE_URL || "";
if (!base) base = deriveBaseFromBackends(realmodel);
var isProxy = /:8788/.test(base), isCCR = /:3456/.test(base);
if (!base && !isProxy && !isCCR) isProxy = true;   // crew standard: all backends route via :8788

// ---- key ----
var key = process.env.CREW_KEY || "";
if ((!key || key === "-") && sess) key = rd(STATE + "/" + sess + ".key").trim();
if (key === "-") key = "";
if (!key) {
  if (isProxy) {
    var mname = realmodel || dmodel;
    var pol = policy[mname] || policy[process.env.CREW_BACKEND || ""] || null;
    if (pol && pol.length) key = pol[0];
  } else if (isCCR) {
    var prov = mprov || dprov, tok = provKey(prov) || provKey(dprov);
    if (tok) key = tok2alias[tok] || (tok.length > 10 ? (tok.slice(0, 4) + "…" + tok.slice(-3)) : tok);
  } else {
    var at = process.env.ANTHROPIC_AUTH_TOKEN || process.env.ANTHROPIC_API_KEY || "";
    if (at) key = tok2alias[at] || (at.length > 10 ? (at.slice(0, 4) + "…" + at.slice(-3)) : at);
  }
}
if (!model) model = "?";
if (!key) key = "?";
process.stdout.write(model + "\t" + key);
