// A blocked cross-origin request, an offline browser, and a DNS failure all
// reach the page as the same "Failed to fetch", which tells a relative nothing.
// The usual cause on this page is the bucket refusing the origin, so say that
// instead of leaving them to guess.

const REACH_FAILURES = /failed to fetch|networkerror|load failed|network request failed/i;

export function reachHint(message: string, origin: string): string {
  if (!REACH_FAILURES.test(message)) return message;
  return (
    `${message}. The browser could not reach Cloudflare Storage: check the connection and try again. ` +
    `If this keeps happening on every network, the bucket is not configured for ${origin} and only ` +
    "the operator can fix that."
  );
}
