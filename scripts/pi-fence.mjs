// consort — Pi tool fence (a Pi extension, loaded with -e on every consort
// call by pi-backend.sh; not auto-discovered).
//
// Pi's built-in tools resolve any path — absolute, ../, ~ — and Pi has no OS
// sandbox, so on their own "read-only" and "workspace-write" describe which
// tools exist, not where they may reach. This hook makes the workdir the
// fence: every path argument of read/grep/find/ls/edit/write must resolve
// (symlinks followed, nearest existing ancestor for new files) inside
// CONSORT_PI_WORKDIR, and in read-only mode bash/edit/write are refused
// outright even if the allowlist ever lets them through. bash in
// workspace-write cannot be fenced here (it is a shell); that is why that
// mode is opt-in.
import { resolve, sep, dirname } from "node:path";
import { realpathSync, existsSync } from "node:fs";
import { homedir } from "node:os";

const MODE = process.env.CONSORT_PI_MODE || "read-only";
const ROOT = realOf(process.env.CONSORT_PI_WORKDIR || process.cwd());
const PATH_TOOLS = new Set(["read", "grep", "find", "ls", "edit", "write"]);
const WRITE_TOOLS = new Set(["bash", "edit", "write"]);

function expand(p) {
  if (p === "~") return homedir();
  if (p.startsWith("~/")) return homedir() + p.slice(1);
  return p;
}
// Real path of the deepest existing ancestor + the untouched remainder, so a
// symlink inside the workdir pointing outside is caught, and a not-yet-
// existing file is judged by where it would land.
function realOf(p) {
  let cur = p, rest = [];
  while (!existsSync(cur)) {
    const parent = dirname(cur);
    if (parent === cur) return p;
    rest.unshift(cur.slice(parent.length + 1));
    cur = parent;
  }
  return [realpathSync(cur), ...rest].join(sep);
}
function inside(p, cwd) {
  const abs = realOf(resolve(cwd, expand(String(p))));
  return abs === ROOT || abs.startsWith(ROOT + sep);
}

export default function (pi) {
  pi.on("tool_call", async (event, ctx) => {
    const name = event.toolName;
    const input = event.input || {};
    const cwd = (ctx && ctx.cwd) || process.cwd();
    if (MODE === "read-only" && WRITE_TOOLS.has(name)) {
      return { block: true, reason: `consort fence: ${name} is not available in read-only mode` };
    }
    if (PATH_TOOLS.has(name)) {
      const p = input.path == null || input.path === "" ? "." : input.path;
      if (!inside(p, cwd)) {
        return { block: true, reason: `consort fence: ${name} on '${p}' resolves outside the workdir ${ROOT}; only files under the workdir may be read or changed` };
      }
    }
    return undefined;
  });
}
