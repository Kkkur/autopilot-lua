// syntax.js -- load every Lua file in the repo without running it.
//
// The relay cannot be booted on the desktop the way the autopilot can, since it
// needs peripherals that only exist in the game. A syntax check is the part of
// that which can be done here, and it catches the mistake that actually happens
// when editing a 400 line file: an unbalanced end.
//
//   node tools/syntax.js

const fsn = require("fs");
const path = require("path");
const { lua, lauxlib, to_luastring } = require("fengari");

const BASE = path.resolve(__dirname, "..");
const files = [];

function walk(dir) {
  for (const name of fsn.readdirSync(dir)) {
    if (name === "node_modules" || name === "deps") continue;
    const full = path.join(dir, name);
    if (fsn.statSync(full).isDirectory()) walk(full);
    else if (name.endsWith(".lua")) files.push(full);
  }
}
walk(BASE);

const L = lauxlib.luaL_newstate();
let bad = 0;

for (const file of files.sort()) {
  const source = fsn.readFileSync(file, "utf8");
  const rel = path.relative(BASE, file).split(path.sep).join("/");
  const status = lauxlib.luaL_loadbuffer(
    L, to_luastring(source), null, to_luastring("@" + rel));
  if (status !== lua.LUA_OK) {
    bad++;
    console.log("FAIL " + rel + ": " + lua.lua_tojsstring(L, -1));
  }
  lua.lua_settop(L, 0);
}

console.log(`${files.length - bad} of ${files.length} files parse`);
process.exit(bad === 0 ? 0 : 1);
