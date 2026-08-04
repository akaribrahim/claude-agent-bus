// Run the board's own script against the board's own data, and print what it
// drew. Used by tests/test_tasks.sh:
//
//     node tests/board-render.js <script.js> <data.json>
//
// Why this exists. Every other assertion about the page is a search of its
// source, and a search cannot tell a value that is drawn from a value that is
// mentioned: a `fillTask` whose body never runs still contains the field names.
// Worse, this repository has already shipped a page that returned HTTP 200 with
// a script that did not parse — rendering nothing at all — and no assertion in
// the suite noticed, because they all looked at JSON or at strings.
//
// So this is not a browser and does not try to be one. It is the smallest DOM
// that the page's reconciler actually uses — createElement, appendChild,
// insertBefore, removeChild, classList, textContent, style.display — with two
// deliberate traps: assigning innerHTML throws, because the page must never
// build markup out of data, and insertBefore with a reference that is not a
// child throws, because that is how a keyed reconciler goes wrong. A node whose
// display is "none" is not printed, so what comes out is what a reader sees.
"use strict";
const fs = require("fs");

function Node(tag) {
  this.tag = tag;
  this.children = [];
  this.style = {};
  this.parentNode = null;
  this.title = "";
  this._cls = [];
  this._text = "";
  const self = this;
  this.classList = {
    add(c) { if (self._cls.indexOf(c) < 0) self._cls.push(c); },
    remove(c) { const i = self._cls.indexOf(c); if (i >= 0) self._cls.splice(i, 1); },
    contains(c) { return self._cls.indexOf(c) >= 0; },
    toggle(c, on) { if (on) this.add(c); else this.remove(c); }
  };
  Object.defineProperty(this, "className", {
    get() { return self._cls.join(" "); },
    set(v) { self._cls = String(v).split(/\s+/).filter(Boolean); }
  });
  Object.defineProperty(this, "textContent", {
    get() { return self._text; },
    set(v) { self._text = String(v); self.children = []; }
  });
  Object.defineProperty(this, "innerHTML", {
    get() { throw new Error("the page read innerHTML"); },
    set() { throw new Error("the page assigned innerHTML"); }
  });
  Object.defineProperty(this, "firstChild", { get() { return self.children[0] || null; } });
  Object.defineProperty(this, "nextSibling", {
    get() {
      const p = self.parentNode;
      if (!p) return null;
      return p.children[p.children.indexOf(self) + 1] || null;
    }
  });
  // Enough for the feed's one measurement: text taller than its box is clipped.
  Object.defineProperty(this, "offsetWidth", { get() { return 1; } });
  Object.defineProperty(this, "scrollHeight", { get() { return 10; } });
  Object.defineProperty(this, "clientHeight", { get() { return 20; } });
}
Node.prototype.appendChild = function (n) {
  if (n.parentNode) n.parentNode.removeChild(n);
  n.parentNode = this;
  this.children.push(n);
  return n;
};
Node.prototype.removeChild = function (n) {
  const i = this.children.indexOf(n);
  if (i < 0) throw new Error("removeChild: not a child of this node");
  this.children.splice(i, 1);
  n.parentNode = null;
  return n;
};
Node.prototype.insertBefore = function (n, ref) {
  if (n.parentNode) n.parentNode.removeChild(n);
  n.parentNode = this;
  if (!ref) { this.children.push(n); return n; }
  const i = this.children.indexOf(ref);
  if (i < 0) throw new Error("insertBefore: reference is not a child of this node");
  this.children.splice(i, 0, n);
  return n;
};
Node.prototype.visible = function () { return this.style.display !== "none"; };
Node.prototype.shownText = function () {
  if (!this.visible()) return "";
  if (this.children.length === 0) return this._text;
  return this.children.map(c => c.shownText()).join(" ");
};

const ids = {};
function byId(id) { return ids[id] || (ids[id] = new Node("div")); }
["count", "wanting", "stuck", "lost", "filters", "agents", "serves", "landing",
 "feed"].forEach(byId);

global.document = {
  createElement: t => new Node(t),
  createTextNode(t) { const n = new Node("#text"); n.textContent = t; return n; },
  getElementById: byId,
  addEventListener() {},
  hasFocus: () => true,
  hidden: false
};
global.window = { addEventListener() {} };
global.localStorage = { getItem: () => null, setItem() {} };
global.setInterval = () => 0;

const data = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));
global.fetch = () => Promise.resolve({ json: () => data });

new Function(fs.readFileSync(process.argv[2], "utf8"))();

// The fetch resolves on a microtask, so the first paint has not happened yet.
setTimeout(() => {
  console.log("HEADER " + [byId("count"), byId("wanting"), byId("stuck")]
    .map(n => n.shownText().trim()).filter(Boolean).join(" "));
  for (const id of ["agents", "serves", "landing", "feed"]) {
    for (const row of byId(id).children) {
      const cells = row.children.map(c => c.shownText().replace(/\s+/g, " ").trim())
        .filter(Boolean);
      console.log(id.toUpperCase() + " [" + row.className + "] " + cells.join(" | "));
    }
  }
}, 0);
