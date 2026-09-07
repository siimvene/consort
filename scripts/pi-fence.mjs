// consort — Pi tool fence (a Pi extension, loaded with -e on every consort
// call by pi-backend.sh; not auto-discovered).
//
// Pi's built-in tools resolve any path — absolute, ../, ~, a leading "@",
// a file:// URL — and Pi has no OS sandbox, so on their own "read-only" and
// "workspace-write" describe which tools exist, not where they may reach.
// This hook makes the workdir the fence: every path argument of
// read/grep/find/ls/edit/write must resolve inside CONSORT_PI_WORKDIR, and
// in read-only mode bash/edit/write are refused outright even if the
// allowlist ever lets them through. bash in workspace-write cannot be
// fenced here (it is a shell); that is why that mode is opt-in.
//
// The path is normalised EXACTLY as Pi's own tools normalise it
// (dist/utils/paths.js normalizePath with the options resolveToCwd passes:
// unicode spaces -> " ", one leading "@" stripped, "~" expanded, file://
// converted), because the fence judges the string the tool will act on. Two
// bypasses were found by a blind review before that was true (a leading "@"
// and file:///etc/...); the test file next to this one pins them.
// Symlinks are followed — including a dangling last component, which
// existsSync-based walking would have treated as a plain new file — and a
// not-yet-existing file is judged by where it would land.
import { resolve, sep, dirname, basename, join, isAbsolute } from "node:path";
import { lstatSync, readlinkSync, realpathSync } from "node:fs";
import { homedir } from "node:os";
import { fileURLToPath } from "node:url";

const UNICODE_SPACES = /[\u00A0\u2000-\u200A\u202F\u205F\u3000]/g;
const PATH_TOOLS = new Set(["read", "grep", "find", "ls", "edit", "write"]);
const WRITE_TOOLS = new Set(["bash", "edit", "write"]);

// Mirror of Pi's normalizePath(input, {normalizeUnicodeSpaces, stripAtPrefix}).
export function normalizeLikePi(input, home = homedir()) {
  let p = String(input).replace(UNICODE_SPACES, " ");
  if (p.startsWith("@")) p = p.slice(1);
  if (p === "~") return home;
  if (p.startsWith("~/")) return join(home, p.slice(2));
  if (/^file:\/\//.test(p)) return fileURLToPath(p);
  return p;
}

// Canonical location a path refers to: parents realpath'd, a symlink in the
// last component followed (even when its target does not exist), and the
// non-existing remainder appended untouched.
export function canonical(p, depth = 0) {
  if (depth > 40) throw new Error("symlink chain too deep");
  let cur = p;
  const rest = [];
  for (;;) {
    let st = null;
    try { st = lstatSync(cur); } catch { st = null; }
    if (st) {
      if (st.isSymbolicLink()) {
        const target = readlinkSync(cur);
        const abs = isAbsolute(target) ? target : resolve(dirname(cur), target);
        return canonical(join(abs, ...rest), depth + 1);
      }
      return join(realpathSync(cur), ...rest);
    }
    const parent = dirname(cur);
    if (parent === cur) return join(cur, ...rest);
    rest.unshift(basename(cur));
    cur = parent;
  }
}

export function resolveLikePi(input, cwd, home = homedir()) {
  const n = normalizeLikePi(input, home);
  return isAbsolute(n) ? resolve(n) : resolve(cwd, n);
}

// True when `input`, as Pi's tool will interpret it from `cwd`, lands inside `root`.
export function inside(input, cwd, root, home = homedir()) {
  let abs;
  try { abs = canonical(resolveLikePi(input, cwd, home)); } catch { return false; }
  return abs === root || abs.startsWith(root + sep);
}

export function judge(toolName, input, cwd, root, mode, home = homedir()) {
  if (mode === "read-only" && WRITE_TOOLS.has(toolName)) {
    return { block: true, reason: `consort fence: ${toolName} is not available in read-only mode` };
  }
  if (PATH_TOOLS.has(toolName)) {
    const raw = input && input.path != null && input.path !== "" ? input.path : ".";
    if (!inside(raw, cwd, root, home)) {
      return { block: true, reason: `consort fence: ${toolName} on '${raw}' resolves outside the workdir ${root}; only files under the workdir may be read or changed` };
    }
  }
  return undefined;
}

export default function (pi) {
  const mode = process.env.CONSORT_PI_MODE || "read-only";
  const root = canonical(resolve(process.env.CONSORT_PI_WORKDIR || process.cwd()));
  pi.on("tool_call", async (event, ctx) => {
    const cwd = (ctx && ctx.cwd) || process.cwd();
    // Fail closed: an exception here must not become an allowed call.
    try {
      return judge(event.toolName, event.input || {}, cwd, root, mode);
    } catch (e) {
      return { block: true, reason: `consort fence: could not judge ${event.toolName}: ${e && e.message}` };
    }
  });
}
