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
// that the page's reconciler actually uses — createElement, createElementNS,
// appendChild, insertBefore, removeChild, classList, textContent, attributes,
// style — with two deliberate traps: assigning innerHTML throws, because the
// page must never build markup out of data, and insertBefore with a reference
// that is not a child throws, because that is how a keyed reconciler goes wrong.
// A node whose display is "none" is not printed, so what comes out is what a
// reader sees.
//
// Two things it is NOT, said out loud so that no assertion is written as though
// it were:
//
//   * It is not a layout engine. getBoundingClientRect gives every node a
//     distinct, deterministic box so that code which measures positions RUNS
//     and what it drew can be checked. Assert on what was drawn and how it is
//     labelled — never on a coordinate.
//   * It does not paint, so it cannot tell you a figure is legible. It can tell
//     you the figure was built, from which fields, and with which shape index.
//
// What it does print is every KEYED ROW, at any depth: a node held in its
// parent's `__rows` map is a row of one of the page's synced lists, and those
// are the units a reader sees. Rows nested inside rows — a declared task under
// the agent that declared it — print as their own line under the section they
// are in, because a fact drawn three levels down is still drawn.
"use strict";
const fs = require("fs");

function Node(tag) {
  this.tag = tag;
  this.children = [];
  this.parentNode = null;
  this.title = "";
  this._cls = [];
  this._text = "";
  this.attrs = {};
  const self = this;
  // A style object rather than a bare one: the page sets an identity hue with
  // setProperty("--h", …), and a custom property assigned as a plain key would
  // have looked like it worked while the figure was drawn in no colour at all.
  this.style = {
    _v: {},
    setProperty(k, v) { this._v[k] = String(v); },
    getPropertyValue(k) { return this._v[k] === undefined ? "" : this._v[k]; },
    removeProperty(k) { delete this._v[k]; }
  };
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
// SVG is written with attributes, not properties, so a page that draws anything
// needs these. "class" is not stored beside the others: it is the class list,
// and keeping two copies of it is how the two come to disagree.
Node.prototype.setAttribute = function (k, v) {
  if (k === "class") { this.className = v; return; }
  this.attrs[k] = String(v);
};
Node.prototype.getAttribute = function (k) {
  if (k === "class") return this.className;
  return this.attrs[k] === undefined ? null : this.attrs[k];
};
Node.prototype.setAttributeNS = function (_ns, k, v) { this.setAttribute(k, v); };
Node.prototype.removeAttribute = function (k) { delete this.attrs[k]; };
// Not layout. A distinct, deterministic box per node, so that code measuring
// where two figures ended up runs and can be checked for WHAT it drew between
// them. Anything asserting on a number out of here is asserting on this
// function, not on the page.
Node.prototype.getBoundingClientRect = function () {
  let x = 0, y = 0, n = this;
  while (n.parentNode) {
    const i = n.parentNode.children.indexOf(n);
    x += 12 + i * 130;
    y += 18 + i * 34;
    n = n.parentNode;
  }
  return { x, y, left: x, top: y, width: 104, height: 64,
           right: x + 104, bottom: y + 64 };
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
  createElementNS: (_ns, t) => new Node(t),
  createTextNode(t) { const n = new Node("#text"); n.textContent = t; return n; },
  getElementById: byId,
  addEventListener() {},
  hasFocus: () => true,
  hidden: false
};
global.window = { addEventListener() {} };
global.localStorage = { getItem: () => null, setItem() {} };
global.setInterval = () => 0;
// Held, not dropped and not run immediately. A page that measures its own
// layout does the measuring in a frame, and a stub that never fires would leave
// every one of those assertions passing while nothing was drawn at all. The
// queue is drained before anything is printed.
let frames = [];
global.requestAnimationFrame = function (cb) { return frames.push(cb); };
global.cancelAnimationFrame = function () {};
function runFrames() {
  for (let pass = 0; pass < 8 && frames.length; pass++) {
    const due = frames;
    frames = [];
    due.forEach(cb => cb(0));
  }
}

const data = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));
global.fetch = () => Promise.resolve({ json: () => data });

new Function(fs.readFileSync(process.argv[2], "utf8"))();

// Anything a reader could press. This page is read-only by contract, and the
// one section that would be tempting to wire up — the finished work that could
// be merged — must stay printed text. Named on the row so that an assertion can
// say "and nothing on it is a control" and have it mean something.
const CONTROLS = { button: 1, a: 1, input: 1, select: 1, textarea: 1, form: 1 };
function controlsIn(node, found) {
  for (const c of node.children) {
    if (CONTROLS[c.tag] && c.visible()) found[c.tag] = 1;
    controlsIn(c, found);
  }
  return found;
}
// Every keyed row under a container, in document order and at any depth: a node
// held in its parent's `__rows` is one row of one of the page's synced lists.
function rows(node, out) {
  const keyed = node.__rows;
  for (const c of node.children) {
    if (keyed && Object.keys(keyed).some(k => keyed[k] === c)) out.push(c);
    rows(c, out);
  }
  return out;
}

// The fetch resolves on a microtask, so the first paint has not happened yet.
setTimeout(() => {
  runFrames();
  console.log("HEADER " + [byId("count"), byId("wanting"), byId("stuck")]
    .map(n => n.shownText().trim()).filter(Boolean).join(" "));
  for (const id of ["agents", "serves", "landing", "feed"]) {
    for (const row of rows(byId(id), [])) {
      const cells = row.children.map(c => c.shownText().replace(/\s+/g, " ").trim())
        .filter(Boolean);
      const what = Object.keys(controlsIn(row, {})).concat(
        row.className ? [row.className] : []).join(" ");
      console.log(id.toUpperCase() + " [" + what + "] " + cells.join(" | "));
    }
  }
}, 0);
