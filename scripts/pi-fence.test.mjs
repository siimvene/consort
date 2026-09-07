// node scripts/pi-fence.test.mjs — pins the fence against the bypasses a
// blind review found (leading "@", file://), plus symlinks, ~, ../, unicode
// spaces and the mode rule. Exit 0 = all green.
import { mkdtempSync, mkdirSync, writeFileSync, symlinkSync, realpathSync, rmSync } from "node:fs";
import { tmpdir, homedir } from "node:os";
import { join, sep } from "node:path";
import { judge, canonical } from "./pi-fence.mjs";

const base = mkdtempSync(join(tmpdir(), "pi-fence-"));
const wd = join(base, "wd"); mkdirSync(wd); mkdirSync(join(wd, "sub"));
writeFileSync(join(wd, "note.txt"), "x");
writeFileSync(join(base, "outside.txt"), "x");
symlinkSync(homedir(), join(wd, "homelink"));
symlinkSync(join(base, "does-not-exist.txt"), join(wd, "dangling"));
symlinkSync(join(wd, "sub"), join(wd, "sublink"));
const root = canonical(wd);
const home = homedir();
let fails = 0;
function expect(name, tool, path, mode, blocked) {
  const r = judge(tool, { path }, root, root, mode, home);
  const got = !!(r && r.block);
  const ok = got === blocked;
  if (!ok) fails++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}: ${tool} ${JSON.stringify(path)} [${mode}] -> ${got ? "blocked" : "allowed"}${r ? " (" + r.reason + ")" : ""}`);
}
// escapes that must be blocked
expect("home via ~", "read", "~/.zshrc", "read-only", true);
expect("bare ~", "ls", "~", "read-only", true);
expect("absolute outside", "read", "/etc/passwd", "read-only", true);
expect("parent", "ls", "..", "read-only", true);
expect("parent file", "read", "../outside.txt", "read-only", true);
expect("@ prefix absolute", "read", "@/etc/passwd", "read-only", true);
expect("@ prefix tilde", "read", "@~/.zshrc", "read-only", true);
expect("file:// url", "read", "file:///etc/passwd", "read-only", true);
expect("file:// url of home", "read", `file://${home}/.zshrc`, "read-only", true);
expect("symlink to home", "read", "homelink/.zshrc", "read-only", true);
expect("dangling symlink outside (write)", "write", "dangling", "workspace-write", true);
expect("dangling symlink outside (read)", "read", "dangling", "read-only", true);
expect("unicode nbsp then parent", "read", " ../outside.txt", "read-only", true);
expect("nonexistent absolute", "read", "/nonexistent/x", "read-only", true);
expect("trailing slash parent", "ls", "../", "read-only", true);
// inside: must be allowed
expect("workdir file", "read", "note.txt", "read-only", false);
expect("workdir dot", "ls", ".", "read-only", false);
expect("workdir empty path", "ls", "", "read-only", false);
expect("workdir absolute", "read", join(root, "note.txt"), "read-only", false);
expect("workdir file:// url", "read", `file://${root}/note.txt`, "read-only", false);
expect("workdir @ prefix", "read", "@note.txt", "read-only", false);
expect("symlink inside to inside", "ls", "sublink", "read-only", false);
expect("new file inside (write, ws-write)", "write", "sub/new.txt", "workspace-write", false);
expect("new nested dirs inside", "write", "a/b/c.txt", "workspace-write", false);
expect("dot-dot that stays inside", "read", "sub/../note.txt", "read-only", false);
// mode rule
expect("bash in read-only", "bash", undefined, "read-only", true);
expect("edit in read-only", "edit", "note.txt", "read-only", true);
expect("write in read-only", "write", "note.txt", "read-only", true);
expect("bash in workspace-write", "bash", undefined, "workspace-write", false);
expect("edit inside in workspace-write", "edit", "note.txt", "workspace-write", false);
expect("edit outside in workspace-write", "edit", "/etc/hosts", "workspace-write", true);
// canonical at filesystem root must not corrupt the path
const c = canonical("/nonexistent-consort-fence-test/x");
const okRoot = c === "/nonexistent-consort-fence-test/x";
if (!okRoot) fails++;
console.log(`${okRoot ? "ok  " : "FAIL"} canonical at /: ${c}`);
rmSync(base, { recursive: true, force: true });
console.log(fails ? `${fails} FAILED` : "all green");
process.exit(fails ? 1 : 0);
