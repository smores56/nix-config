// A recovery link carries the recovery password itself in the URL fragment:
//
//   https://recovery.sammohr.dev/#<password>
//
// The fragment is never sent to the server, so it stays out of Cloudflare's
// access logs, out of any proxy, and out of the Referer header. It does sit in
// the browser's address bar until main.ts strips it, and it is printed on the
// same paper as the password, so it is the password in another form.

export function recoveryLink(pageUrl: string, password: string): string {
  const base = pageUrl.includes("#") ? pageUrl.slice(0, pageUrl.indexOf("#")) : pageUrl;
  return `${base}#${encodeURIComponent(password)}`;
}

export function passwordFromHash(hash: string): string | null {
  const raw = hash.startsWith("#") ? hash.slice(1) : hash;
  if (!raw) return null;
  try {
    return decodeURIComponent(raw) || null;
  } catch {
    // A hand-typed fragment can contain a bare "%"; take it literally.
    return raw;
  }
}
