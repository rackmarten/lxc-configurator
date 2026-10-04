// Run with: node --test tests/incinerator.test.mjs
// Drives modules/system/incinerator/incinerator with stubbed docker, df and
// journalctl on PATH (same approach as homelab/scripts/rootproxy.test.mjs).
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

const script = new URL("../modules/system/incinerator/incinerator", import.meta.url).pathname;
const hoursAgo = (h) => new Date(Date.now() - h * 3600_000);
const anon = "a".repeat(64);

// policy: object written to the policy file, a raw string, or undefined (no file).
function run(args, { policy, usage = 90, stopped = [], volumes = [] } = {}) {
  const dir = mkdtempSync(join(tmpdir(), "incinerator-"));
  const bin = join(dir, "bin");
  mkdirSync(bin);
  const stub = (name, body) => {
    writeFileSync(join(bin, name), `#!/usr/bin/env bash\n${body}\n`);
    chmodSync(join(bin, name), 0o755);
  };
  const record = (file) => `printf '%s\\n' "$@" >> "${join(dir, file)}"; echo --- >> "${join(dir, file)}"`;
  stub("df", `echo "Filesystem 1024-blocks Used Available Capacity Mounted on"; echo "/dev/x 100 ${usage} 10 ${usage}% /"`);
  stub("journalctl", `${record("journalctl.log")}\necho "Vacuuming done, freed 16.0M of archived journals from /var/log/journal." >&2`);
  {
    const inspect = stopped.map((c) => `${c.id} ${c.finished.toISOString()} ${c.size}`).join("\n");
    stub("docker", `${record("docker.log")}
case "$1 $2" in
  "ps -aq") ${stopped.length ? `printf '%s\\n' ${stopped.map((c) => c.id).join(" ")}` : ":"} ;;
  "inspect --size") cat <<'EOF'\n${inspect}\nEOF
  ;;
  "image prune") echo "Total reclaimed space: 1.5GB" ;;
  "builder prune") echo "Total:	2kB" ;;
  "volume ls") ${volumes.length ? `printf '%s\\n' ${volumes.join(" ")}` : ":"} ;;
  "volume inspect") echo /nonexistent ;;
esac`);
  }
  const policyFile = join(dir, "incinerator.json");
  if (policy !== undefined) writeFileSync(policyFile, typeof policy === "string" ? policy : JSON.stringify(policy));
  const res = spawnSync("bash", [script, ...args], {
    encoding: "utf8",
    env: { PATH: `${bin}:/usr/bin:/bin`, INCINERATOR_POLICY: policyFile, INCINERATOR_LOCK: join(dir, "lock") },
  });
  const read = (f) => (existsSync(join(dir, f)) ? readFileSync(join(dir, f), "utf8") : "");
  const calls = (f) => read(f).split("---\n").filter(Boolean).map((c) => c.trimEnd().split("\n"));
  const lines = res.stdout.trim().split("\n").filter(Boolean);
  return { dir, code: res.status, stderr: res.stderr, lines, log: lines.length ? JSON.parse(lines.at(-1)) : null, docker: calls("docker.log"), journalctl: calls("journalctl.log") };
}

const has = (calls, ...argv) => calls.some((c) => argv.every((a, i) => c[i] === a));

test("built-in defaults: docker images, build cache and containers, no volumes, no journald", () => {
  const r = run(["--daily"]);
  assert.equal(r.code, 0, r.stderr);
  assert.equal(r.log.policy, "builtin");
  assert.ok(has(r.docker, "image", "prune", "-a", "-f"));
  assert.ok(has(r.docker, "builder", "prune"));
  assert.ok(has(r.docker, "ps", "-aq"));
  assert.ok(!has(r.docker, "volume", "ls"), "anonymousVolumes defaults to false");
  assert.deepEqual(r.journalctl, []);
});

test("log line shape: one JSON line with pass, usage and freed bytes per category", () => {
  const r = run(["--daily"], { policy: { version: 1, journald: "200M" } });
  assert.equal(r.lines.length, 1);
  assert.equal(r.log.pass, "daily");
  assert.equal(r.log.dryRun, false);
  assert.equal(r.log.usageBefore, 90);
  assert.equal(r.log.usageAfter, 90);
  assert.deepEqual(Object.keys(r.log.freedBytes).sort(), ["apt", "buildCache", "containers", "images", "journald", "paths", "volumes"]);
  assert.equal(r.log.freedBytes.images, 1_500_000_000);
  assert.equal(r.log.freedBytes.buildCache, 2000);
  assert.equal(r.log.freedBytes.journald, 16 * 1024 * 1024);
  assert.equal(r.log.freedTotal, 1_500_000_000 + 2000 + 16 * 1024 * 1024);
  assert.deepEqual(r.log.errors, []);
  assert.ok(has(r.journalctl, "--vacuum-size=200M"));
});

test("invalid policy: logs, exits non-zero and burns nothing", () => {
  for (const policy of ["{not json", { version: 2 }, { version: 1, threshold: "high" }, { version: 1, paths: [{ glob: "/*", maxAgeHours: 1 }] }, { version: 1, docker: { images: "yes" } }]) {
    const r = run(["--daily"], { policy });
    assert.notEqual(r.code, 0, JSON.stringify(policy));
    assert.deepEqual(r.docker, [], "no docker calls");
    assert.equal(r.log.skipped, true);
    assert.match(r.log.errors[0], /invalid policy/);
  }
});

test("daily keeps containers stopped under 24h and filters build cache by 72h", () => {
  const stopped = [{ id: "old", finished: hoursAgo(30), size: 100 }, { id: "new", finished: hoursAgo(2), size: 50 }];
  const r = run(["--daily"], { stopped });
  assert.equal(r.code, 0, r.stderr);
  assert.ok(has(r.docker, "rm", "old"));
  assert.ok(!has(r.docker, "rm", "new"));
  assert.equal(r.log.freedBytes.containers, 100);
  assert.ok(r.docker.some((c) => c[0] === "builder" && c.includes("until=72h")));
});

test("pressure drops the age filters", () => {
  const stopped = [{ id: "old", finished: hoursAgo(30), size: 100 }, { id: "new", finished: hoursAgo(2), size: 50 }];
  const r = run(["--pressure"], { stopped, usage: 90 });
  assert.equal(r.code, 0, r.stderr);
  assert.ok(has(r.docker, "rm", "old") && has(r.docker, "rm", "new"));
  assert.equal(r.log.freedBytes.containers, 150);
  assert.ok(!r.docker.some((c) => c[0] === "builder" && c.includes("until=72h")));
});

test("pressure below the threshold does nothing", () => {
  const r = run(["--pressure"], { usage: 70, policy: { version: 1, threshold: 80 } });
  assert.equal(r.code, 0, r.stderr);
  assert.deepEqual(r.docker, []);
  assert.equal(r.log.skipped, true);
  assert.equal(r.log.threshold, 80);
  assert.equal(r.log.usageBefore, 70);
  const at = run(["--pressure"], { usage: 80, policy: { version: 1, threshold: 80 } });
  assert.ok(at.docker.length > 0, "acts at exactly the threshold");
});

test("anonymous volumes only when enabled; named volumes never", () => {
  const volumes = [anon, "pinboard_pgdata", "b".repeat(63)];
  const r = run(["--daily"], { volumes, policy: { version: 1, docker: { anonymousVolumes: true } } });
  assert.equal(r.code, 0, r.stderr);
  assert.ok(has(r.docker, "volume", "ls", "-q", "--filter", "dangling=true"));
  const removed = r.docker.filter((c) => c[0] === "volume" && c[1] === "rm").map((c) => c[2]);
  assert.deepEqual(removed, [anon]);
  assert.ok(!r.docker.some((c) => c[1] === "prune" && c[0] === "volume"), "never volume prune");
});

function makeEntries(root, specs) {
  mkdirSync(root, { recursive: true });
  for (const [name, hours, bytes] of specs) {
    const p = join(root, name);
    writeFileSync(p, Buffer.alloc(bytes));
    utimesSync(p, hoursAgo(hours), hoursAgo(hours));
  }
}

test("paths: age rule first, then oldest first until under maxSizeMb", () => {
  const mb = 1024 * 1024;
  const root = mkdtempSync(join(tmpdir(), "incinerator-size-"));
  makeEntries(root, [["ancient", 100, 10], ["a", 10, mb], ["b", 5, mb], ["c", 1, mb]]);
  const policy = { version: 1, docker: { images: false, buildCache: false, stoppedContainers: false }, paths: [{ glob: `${root}/*`, maxAgeHours: 48, maxSizeMb: 2 }] };
  const r2 = run(["--daily"], { policy });
  assert.equal(r2.code, 0, r2.stderr);
  assert.ok(!existsSync(join(root, "ancient")), "older than maxAgeHours");
  assert.ok(!existsSync(join(root, "a")), "oldest removed to get under 2MB");
  assert.ok(existsSync(join(root, "b")) && existsSync(join(root, "c")));
  assert.equal(r2.log.freedBytes.paths, 10 + mb);
});

test("paths: pressure uses pressureMaxAgeHours", () => {
  const root = mkdtempSync(join(tmpdir(), "incinerator-paths-"));
  makeEntries(root, [["x", 10, 1], ["y", 1, 1]]);
  const policy = { version: 1, docker: { images: false, buildCache: false, stoppedContainers: false }, paths: [{ glob: `${root}/*`, maxAgeHours: 48, pressureMaxAgeHours: 5 }] };
  const daily = run(["--daily", "--dry-run"], { policy });
  assert.equal(daily.log.freedBytes.paths, 0);
  const r = run(["--pressure"], { policy, usage: 95 });
  assert.equal(r.code, 0, r.stderr);
  assert.ok(!existsSync(join(root, "x")));
  assert.ok(existsSync(join(root, "y")));
});

test("dry run changes nothing", () => {
  const root = mkdtempSync(join(tmpdir(), "incinerator-dry-"));
  makeEntries(root, [["x", 100, 5]]);
  const stopped = [{ id: "old", finished: hoursAgo(30), size: 100 }];
  const policy = { version: 1, paths: [{ glob: `${root}/*`, maxAgeHours: 1 }] };
  const r = run(["--daily", "--dry-run"], { policy, stopped });
  assert.equal(r.code, 0, r.stderr);
  assert.equal(r.log.dryRun, true);
  assert.ok(existsSync(join(root, "x")));
  assert.equal(r.log.freedBytes.paths, 5);
  assert.ok(!r.docker.some((c) => c[0] === "rm" || c[1] === "prune"));
});

test("a mode flag is required", () => {
  assert.equal(run([]).code, 2);
  assert.equal(run(["--bogus"]).code, 2);
});
