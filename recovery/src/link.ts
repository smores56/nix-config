// A recovery link carries the recovery password in the URL fragment:
//
//   https://recovery.sammohr.dev/#recovery-password=<password>
//
// The fragment is never sent to the server, so it stays out of Cloudflare's
// access logs, out of any proxy, and out of the Referer header. It does still
// live in the letter and in the browser's address bar until main.ts strips it,
// so the letter treats the link exactly like the password.

export const RECOVERY_PASSWORD_PARAM = "recovery-password";

export function recoveryLink(pageUrl: string, password: string): string {
  const url = new URL(pageUrl);
  url.hash = new URLSearchParams({ [RECOVERY_PASSWORD_PARAM]: password }).toString();
  return url.toString();
}

export function passwordFromHash(hash: string): string | null {
  const raw = hash.startsWith("#") ? hash.slice(1) : hash;
  if (!raw) return null;
  const value = new URLSearchParams(raw).get(RECOVERY_PASSWORD_PARAM);
  return value ? value : null;
}
