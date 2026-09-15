// sim.js -- run tools/sim.lua on a desktop, through fengari.
//
// There is no Lua on a normal Windows box and no CC: Tweaked outside the game,
// so this loads the sources into a Lua 5.3 VM in node and lets sim.lua stub the
// rest. Install once with `npm install fengari` in this folder, then:
//
//   node tools/sim.js
//   node tools/sim.js --frames 600
//
// It prints the screen the program drew and where the toy ship ended up.

const fsn = require("fs");
const nodePath = require("path");
const { lua, lauxlib, lualib, to_luastring } = require("fengari");

const BASE = nodePath.resolve(__dirname, "..").split(nodePath.sep).join("/");
const SRC = BASE + "/src/";
const SIM = BASE + "/tools/sim.lua";

const files = {};
function walk(dir) {
  for (const name of fsn.readdirSync(dir)) {
    const full = nodePath.join(dir, name);
    if (fsn.statSync(full).isDirectory()) walk(full);
    else if (name.endsWith(".lua")) {
      files[full.split(nodePath.sep).join("/")] = fsn.readFileSync(full, "utf8");
    }
  }
}
walk(BASE + "/src");

const args = process.argv.slice(2);

let boot = "SIM_FILES = {}\n";
for (const [key, value] of Object.entries(files)) {
  boot += "SIM_FILES[ [[" + key + "]] ] = [==[\n" + value + "]==]\n";
}
boot += "SIM_SRC = [[" + SRC + "]]\n";
boot += "arg = {" + args.map((a) => "[[" + a + "]]").join(", ") + "}\n";
boot += "assert(loadfile([[" + SIM + "]]))()\n";

const L = lauxlib.luaL_newstate();
lualib.luaL_openlibs(L);

if (lauxlib.luaL_loadbuffer(L, to_luastring(boot), null, to_luastring("@sim")) !== lua.LUA_OK) {
  console.log("load error: " + lua.lua_tojsstring(L, -1));
  process.exit(1);
}
if (lua.lua_pcall(L, 0, 0, 0) !== lua.LUA_OK) {
  console.log("runtime error: " + lua.lua_tojsstring(L, -1));
  process.exit(1);
}
