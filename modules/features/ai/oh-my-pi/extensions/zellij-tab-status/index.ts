/**
 * zellij-tab-status: Show agent status in the Zellij tab name.
 *
 * Subscribes to omp lifecycle events and appends a status suffix to the
 * current Zellij tab name while the agent is working. Restores the
 * original name when idle.
 *
 * Only activates when $ZELLIJ_PANE_ID is set (running inside Zellij).
 * Managed by home-manager. Manual edits are clobbered.
 */
import { type ExtensionAPI } from "@oh-my-pi/pi-coding-agent";
import { execSync } from "node:child_process";

function inZellij(): boolean {
	return !!process.env.ZELLIJ_PANE_ID;
}

function renameTab(name: string): void {
	try {
		execSync(`zellij action rename-tab -- ${JSON.stringify(name)}`, {
			timeout: 2000,
			stdio: "ignore",
		});
	} catch {
		// best-effort; don't crash the extension
	}
}

export default function zellijTabStatusExtension(pi: ExtensionAPI): void {
	if (!inZellij()) {
		return;
	}

	pi.logger.info("zellij-tab-status: loaded");

	let originalName: string | undefined;
	let active = false;

	function saveOriginal(): void {
		if (originalName !== undefined) return;
		try {
			const out = execSync(
				"zellij action list-tabs --json --state",
				{ timeout: 2000, encoding: "utf-8" },
			);
			const tabs = JSON.parse(out);
			const current = Array.isArray(tabs)
				? tabs.find((t: any) => t.active || t.is_active)
				: null;
			if (current?.name) {
				originalName = current.name;
			}
		} catch {
			// can't read tab name; skip restore
		}
	}

	function setStatus(suffix: string): void {
		const base = originalName || "";
		if (!base) return;
		renameTab(`${base} · ${suffix}`);
	}

	function restoreOriginal(): void {
		if (originalName) {
			renameTab(originalName);
		}
	}

	// Subscribe to ALL likely events so we can see which ones fire
	for (const eventName of [
		"agent_start",
		"agent_end",
		"turn_start",
		"turn_end",
		"tool_call",
		"tool_result",
		"tool_execution_start",
		"tool_execution_end",
		"tool_approval_requested",
		"tool_approval_resolved",
		"session_stop",
		"session_shutdown",
		"before_agent_start",
		"message_start",
		"message_end",
	]) {
		pi.on(eventName as any, ((event: any) => {
			pi.logger.info(`zellij-tab-status: event fired: ${eventName}`);

			switch (eventName) {
				case "agent_start":
				case "turn_start":
				case "before_agent_start":
					saveOriginal();
					active = true;
					setStatus("thinking");
					break;

				case "tool_call":
				case "tool_execution_start":
					if (active) {
						const name =
							typeof event?.name === "string"
								? event.name
								: typeof event?.tool === "string"
									? event.tool
									: undefined;
						if (name) {
							setStatus(name);
						}
					}
					break;

				case "tool_result":
				case "tool_execution_end":
					if (active) {
						setStatus("thinking");
					}
					break;

				case "tool_approval_requested":
					setStatus("waiting");
					break;

				case "tool_approval_resolved":
					if (active) {
						setStatus("thinking");
					}
					break;

				case "agent_end":
				case "turn_end":
				case "session_stop":
				case "session_shutdown":
					active = false;
					restoreOriginal();
					break;
			}
		}) as any);
	}

	pi.logger.info("zellij-tab-status: all event handlers registered");
}
