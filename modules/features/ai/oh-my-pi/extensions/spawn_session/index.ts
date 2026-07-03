/**
 * spawn_session: create a worktree and spawn a new omp session in a
 * new Zellij tab, behind a confirmation dialog. oh-my-pi port of maki's
 * modules/features/ai/maki/lua/spawn_session.lua.
 *
 * Caller resolves the branch name first:
 *   agent-branch-name --slug <slug> --task "<task>"
 * then passes branch + prompt. The prompt rides in OMP_START_PROMPT (never
 * argv) and is expanded by the outer bash spawned below, so it can't leak via
 * `ps`/history — mirroring maki's START_PROMPT pattern.
 *
 * Managed by home-manager. Manual edits are clobbered.
 */
import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";

const TAB_TIMEOUT_MS = 10_000;
const WT_TIMEOUT_MS = 20_000;

/** POSIX single-quoting for embedding controlled strings in a bash snippet. */
function shellQuote(s: string): string {
	return "'" + s.replace(/'/g, "'\\''") + "'";
}

/** Collapse to the first line, trim, cap at 120 chars. */
function previewPrompt(prompt: string): string {
	const firstLine = (prompt.match(/^[^\n]*/) ?? [""])[0];
	let preview = firstLine.replace(/\s+/g, " ").trim();
	if (preview.length > 120) preview = preview.slice(0, 117) + "...";
	return preview;
}

export default function spawnSessionExtension(pi: ExtensionAPI): void {
	const { z } = pi.zod;

	pi.registerTool({
		name: "spawn_session",
		label: "Spawn Session",
		description: [
			"Spawn a new interactive omp session in a new Zellij tab (with a worktree).",
			"",
			"BEFORE calling this, generate the branch name via:",
			'  agent-branch-name --slug <slug> --task "<task>"',
			"and prepare the session prompt.",
			"",
			"Workflow:",
			"1. Shows a confirmation dialog with the branch name and task description",
			"2. Creates the worktree via `wt switch --create --no-hooks --no-cd <branch> --format json`",
			"3. Opens a new Zellij tab and runs omp in the worktree directory",
			"",
			"Use for long-running feature work that deserves its own isolated session.",
			"",
			"This tool cannot be batched.",
		].join("\n"),
		parameters: z.object({
			branch: z
				.string()
				.describe(
					'Full branch name (e.g. "smores/my-feature"). Generate via:\n' +
						'agent-branch-name --slug <slug> --task "<task>"',
				),
			prompt: z
				.string()
				.describe(
					"Full prompt for the new omp session (becomes its first user message). " +
						"E.g. 'Implement user authentication with OAuth2'",
				),
			task: z
				.string()
				.optional()
				.describe(
					"Short display label for the confirmation question and the Zellij tab name " +
						"(defaults to the worktree name, derived from the branch's last path segment).",
				),
		}),
		async execute(_toolCallId, params, signal, _onUpdate, ctx) {
			const branch = (params.branch ?? "").trim();
			const prompt = params.prompt ?? "";
			if (!branch || !prompt) {
				return {
					content: [{
						type: "text",
						text: "error: branch and prompt are required",
					}],
					isError: true,
					details: { error: "missing branch or prompt" },
				};
			}

			const worktreeName = (branch.match(/[^/]+$/) ?? [branch])[0] ?? branch;
			const displayLabel = (params.task ?? "").trim() || worktreeName;

			const message = [
				"Start a new session?",
				"",
				`- **Branch:** \`${branch}\``,
				`- **Worktree:** \`${worktreeName}\``,
				`- **Prompt:** ${previewPrompt(prompt)}`,
			].join("\n");

			// Fail-closed: dismiss/abort → cancelled.
			let confirmed = false;
			try {
				confirmed = await ctx.ui.confirm("Spawn session?", message, { signal });
			} catch {
				confirmed = false;
			}
			if (!confirmed) {
				return {
					content: [{ type: "text", text: "(cancelled by user)" }],
					details: { cancelled: true, branch },
				};
			}

			// Idempotent: retry without --create when the branch already exists.
			// wt emits JSON on the first stdout line; fall back to a
			// $root/.worktrees/<name> path if the path field can't be parsed.
			const resolveScript = [
				"set -euo pipefail",
				`branch=${shellQuote(branch)}`,
				`wt_output=$(wt switch --create --no-hooks --no-cd "$branch" --format json 2>&1) || {`,
				`  case "$wt_output" in`,
				`    *"already exists"*)`,
				`      wt_output=$(wt switch --no-hooks --no-cd "$branch" --format json 2>&1) || { echo "ERR:$wt_output"; exit 1; }`,
				`      ;;`,
				`    *)`,
				`      echo "ERR:$wt_output"`,
				`      exit 1`,
				`      ;;`,
				`  esac`,
				`}`,
				`path=$(printf '%s' "$wt_output" | head -n1 | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('path',''))" 2>/dev/null) || path=""`,
				`if [ -z "$path" ]; then`,
				`  root=$(git rev-parse --show-toplevel 2>/dev/null) || root=""`,
				`  if [ -n "$root" ]; then`,
				`    wt_name=${shellQuote(worktreeName)}`,
				`    path="$root/.worktrees/$wt_name"`,
				`  fi`,
				`fi`,
				`if [ -z "$path" ]; then`,
				`  echo "ERR:could not determine worktree path from wt output: $wt_output"`,
				`  exit 1`,
				`fi`,
				`printf '%s' "$path"`,
			].join("\n");

			let resolve: {
				stdout: string;
				stderr: string;
				code: number;
				killed: boolean;
			};
			try {
				resolve = await pi.exec("bash", ["-c", resolveScript], {
					cwd: ctx.cwd,
					signal,
					timeout: WT_TIMEOUT_MS,
				});
			} catch (err) {
				const msg = err instanceof Error ? err.message : String(err);
				return {
					content: [{ type: "text", text: `error spawning session: ${msg}` }],
					isError: true,
					details: { error: msg, phase: "exec-wt" },
				};
			}
			if (resolve.killed && signal?.aborted) {
				return {
					content: [{ type: "text", text: "Cancelled" }],
					details: { cancelled: true, phase: "wt" },
				};
			}
			if (resolve.code !== 0) {
				const out = resolve.stdout.trim();
				const err = (out.startsWith("ERR:") ? out.slice(4) : out) ||
					resolve.stderr || "unknown wt error";
				return {
					content: [{
						type: "text",
						text: `error spawning session: ${err.trim()}`,
					}],
					isError: true,
					details: { error: err.trim(), phase: "wt", code: resolve.code },
				};
			}

			const path = resolve.stdout.trim();
			if (!path) {
				return {
					content: [{
						type: "text",
						text: "error: worktree path came back empty",
					}],
					isError: true,
					details: { error: "empty worktree path", phase: "wt" },
				};
			}

			// Prompt via OMP_START_PROMPT, expanded by this outer bash (which has
			// the env injected) rather than inside the new-tab process — Zellij
			// doesn't reliably propagate the caller's env to daemon-spawned tabs.
			// The spawned omp re-enters the smolvm sandbox (same as the `o` abbr).
			const spawnScript =
				`exec zellij action new-tab -n ${
					shellQuote(`π - ${displayLabel}`)
				} -c ${shellQuote(path)}` +
				` --close-on-exit -- exec smolvm-agent omp -- "$OMP_START_PROMPT"`;

			let proc: import("bun").Subprocess<"ignore", "pipe", "pipe">;
			try {
				proc = Bun.spawn(["bash", "-c", spawnScript], {
					cwd: ctx.cwd,
					stdin: "ignore",
					stdout: "pipe",
					stderr: "pipe",
					env: { ...Bun.env, OMP_START_PROMPT: prompt },
					detached: true,
				});
			} catch (err) {
				const msg = err instanceof Error ? err.message : String(err);
				return {
					content: [{
						type: "text",
						text: `error spawning zellij tab: ${msg}`,
					}],
					isError: true,
					details: { error: msg, phase: "spawn", branch, path },
				};
			}

			// `zellij action new-tab` can block while the new tab is foreground;
			// race a fuse so the tool never hangs (detached keeps the tab alive).
			const outcome = await Promise.race([
				proc.exited.then((code) => ({ code, timedOut: false })),
				new Promise<{ code: number | null; timedOut: true }>((resolve) =>
					setTimeout(
						() => resolve({ code: null, timedOut: true }),
						TAB_TIMEOUT_MS,
					)
				),
			]);

			// Drain child pipes so they don't linger.
			try {
				await Promise.allSettled([
					new Response(proc.stdout).text(),
					new Response(proc.stderr).text(),
				]);
			} catch {
				// best-effort
			}

			if (outcome.timedOut) {
				return {
					content: [
						{
							type: "text",
							text: `Opened Zellij tab **${displayLabel}** running omp ` +
								`(\`zellij action\` did not return in 10s; tab likely live).\n` +
								`- Branch: \`${branch}\`\n- Worktree: \`${path}\``,
						},
					],
					details: {
						branch,
						path,
						worktreeName,
						tabOpened: true,
						softTimeout: true,
					},
				};
			}

			if (outcome.code !== 0) {
				let stderrText = "";
				try {
					stderrText = await new Response(proc.stderr).text();
				} catch {
					// ignore
				}
				const msg = (stderrText || `exit ${outcome.code}`).trim();
				return {
					content: [
						{
							type: "text",
							text:
								`Created worktree \`${path}\` (branch \`${branch}\`) but the Zellij tab ` +
								`did not open — \`zellij action new-tab\` failed (exit ${outcome.code}): ${msg}`,
						},
					],
					isError: true,
					details: {
						error: msg,
						phase: "spawn",
						code: outcome.code,
						branch,
						path,
						worktreeCreated: true,
					},
				};
			}

			return {
				content: [
					{
						type: "text",
						text: `Started omp session in Zellij tab **${displayLabel}**\n` +
							`- Worktree: \`${path}\`\n- Branch: \`${branch}\``,
					},
				],
				details: { branch, path, worktreeName, tabOpened: true },
			};
		},
	});
}
