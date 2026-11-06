// Renders the recovery kit: two letter sets that the operator prints and seals,
// and the plain-text file that sits at the root of each USB drive. Everything
// here carries the stable root of trust only (Bitwarden + the PWA password and
// URL); the values are supplied by the caller and never stored in the repo.

export type KitValues = {
  recipient: string;
  operatorName: string;
  bitwardenEmail: string;
  bitwardenPassword: string;
  recoveryCode: string;
  pwaPassword: string;
  pwaUrl: string;
  fallbackUrl: string;
};

export function kitSlug(name: string): string {
  const slug = name
    .toLowerCase()
    .normalize("NFKD")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 60);
  return slug || "family";
}

function escapeHtml(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

const STYLE = `
  @media print { @page { margin: 18mm; } .page { page-break-after: always; } }
  body { font: 12pt/1.5 Georgia, serif; color: #111; max-width: 46rem; margin: 2rem auto; }
  h1 { font-size: 20pt; margin: 0 0 0.5rem; }
  h2 { font-size: 13pt; margin: 1.6rem 0 0.4rem; }
  .cover { text-align: center; padding-top: 6rem; }
  .cover p { font-size: 14pt; }
  .secret { font: 12pt/1.4 ui-monospace, monospace; border: 1px solid #999; padding: 0.5rem 0.75rem; }
  .secret b { display: block; font: 9pt/1.4 system-ui, sans-serif; color: #555; }
  .warn { border-left: 4px solid #a00; padding-left: 0.8rem; }
  ol li, ul li { margin: 0.35rem 0; }
  .muted { color: #555; font-size: 10pt; }
`;

function secret(label: string, value: string): string {
  return `<div class="secret"><b>${escapeHtml(label)}</b>${escapeHtml(value)}</div>`;
}

export function renderLetter(values: KitValues): string {
  const name = escapeHtml(values.recipient);
  const operator = escapeHtml(values.operatorName);
  const email = escapeHtml(values.bitwardenEmail);
  const pwa = escapeHtml(values.pwaUrl);
  const fallback = escapeHtml(values.fallbackUrl);

  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Recovery kit for ${name}</title>
<style>${STYLE}</style>
</head>
<body>
<section class="page cover">
  <h1>For ${name}</h1>
  <p><strong>Private. From ${operator}.</strong></p>
  <p>Do not open this envelope unless ${operator} has died or can no longer act for himself.
  If you are not sure, wait and talk to the other person who has an envelope like this one.</p>
  <p class="muted">If you did open it: nothing is broken. Keep the envelope and the small USB drive together.</p>
</section>

<section class="page">
  <h1>What this is</h1>
  <p>${operator} set this up so you can get into his accounts and his files without needing
  anything from his computers. There are two things inside: this letter and a small USB drive
  with the same information. Either one is enough.</p>
  <p>Everything below is a copy for you. Changing it does not lock ${operator} out of anything,
  and you should not change any passwords until you are sure you need to.</p>

  <h2>1. His password manager</h2>
  <p>Almost every password he has is inside a password manager called Bitwarden. Open
  <strong>bitwarden.com</strong> in any browser, or the Bitwarden app, and sign in:</p>
  ${secret("Bitwarden e-mail", values.bitwardenEmail)}
  ${secret("Bitwarden master password", values.bitwardenPassword)}
  ${secret("Two-step recovery code (use it if it asks for a code)", values.recoveryCode)}
  <p class="muted">The recovery code only works once it is needed, so keep it with this letter.
  If the site asks you to approve a login from another device, use "Use recovery code" instead.</p>

  <h2>2. The instructions page</h2>
  <p>${operator} made a web page that explains, account by account, what to open and what to do.
  It is the same page on every device, and it asks for one password of its own:</p>
  ${secret("Instructions page", pwa)}
  ${secret("Instructions page password", values.pwaPassword)}
  <p class="muted">If that address ever stops working, try ${fallback}.</p>

  <h2>3. His files: photos and documents</h2>
  <p>The photos and documents are backed up nightly to cloud storage. The instructions page can
  download them, but the full library is large (tens of gigabytes), so use a Mac for that:</p>
  <ul>
    <li>On the Mac, open the instructions page in <strong>Google Chrome</strong> (not Safari).</li>
    <li>Unlock the page with the password above, then press "Restore everything to a folder".</li>
    <li>Pick a folder, for example on an external drive, and leave the tab open while it works.</li>
    <li>If it stops, run it again: files that are already there are skipped.</li>
  </ul>
  <p class="muted">Safari can still open the page, read the instructions, and download single files.</p>

  <h2>4. His e-mail</h2>
  <p>His e-mail is a Tuta account, also inside Bitwarden. Sign in to it early: free Tuta accounts
  are deleted after six months without a login, so a message sitting there can disappear.</p>

  <h2>Please do not</h2>
  <ul class="warn">
    <li>Send these passwords by e-mail, text, or chat, or type them into a page someone links you.</li>
    <li>Change the Bitwarden master password before you have everything you need.</li>
    <li>Throw this letter or the USB drive away: they are the only copies.</li>
  </ul>
  <p class="muted">Prepared by ${operator}. The other person holding an envelope has an identical
  letter and drive, so you can check each other's copy.</p>
</section>
</body>
</html>
`;
}

export function renderStartHere(values: KitValues): string {
  return `RECOVERY KIT - ${values.recipient}
From ${values.operatorName}. Private.

Open the envelope marked "${values.recipient}" before using this drive. The letter and this
drive hold the same information; you only need one of them.

1. PASSWORD MANAGER (Bitwarden): https://bitwarden.com
   E-mail:            ${values.bitwardenEmail}
   Master password:   ${values.bitwardenPassword}
   Recovery code:     ${values.recoveryCode}

2. INSTRUCTIONS PAGE
   Address:           ${values.pwaUrl}
   Fallback address:  ${values.fallbackUrl}
   Page password:     ${values.pwaPassword}

3. FILES (photos, documents)
   Open the instructions page in Google Chrome on a Mac and press
   "Restore everything to a folder". Safari can read the page and download
   single files, but it cannot restore everything at once.
   The library is large; use an external drive and leave the tab open.

4. E-MAIL
   His e-mail account is in Bitwarden. Log in early: free Tuta accounts are
   deleted after six months without a login.

Do not share these passwords. Do not change the Bitwarden password until you
have everything you need.

The other person with an envelope has an identical copy.
`;
}

export function renderLabel(values: KitValues): string {
  const name = escapeHtml(values.recipient);
  const operator = escapeHtml(values.operatorName);
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Drive label for ${name}</title>
<style>
  body { font: 14pt/1.4 system-ui, sans-serif; margin: 0; }
  .label { width: 70mm; height: 40mm; border: 1px dashed #999; padding: 3mm; box-sizing: border-box; }
  .label h1 { font-size: 13pt; margin: 0 0 1mm; }
  .label p { margin: 0; font-size: 9pt; }
  .label .big { font-size: 10pt; font-weight: 700; margin-top: 2mm; }
</style>
</head>
<body>
<div class="label">
  <h1>Recovery kit - ${name}</h1>
  <p>From ${operator}. Contains passwords.</p>
  <p class="big">Do not open or plug in unless ${operator} has died or cannot act.</p>
  <p>Keep sealed, with the letter of the same name.</p>
</div>
</body>
</html>
`;
}
