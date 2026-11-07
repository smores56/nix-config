// Builds the printed recovery kit: one letter, one drive label, one plain-text
// drive file and a checklist per family member. Everything it writes is
// plaintext, so it refuses to write inside the repository and creates the
// output tree 0700 with 0600 files.
//
//   deno task kit [--out ~/recovery-kit] [--page-url <url>] [--fallback-url <url>]
//                 [--operator <name>] [--blob public/data-keys.enc]

import { kitSlug, type KitValues, renderLabel, renderLetter, renderStartHere } from "../src/kit.ts";
import { promptHidden, promptVisible, verifyBlobPassword } from "./prompt.ts";

const DEFAULT_PAGE_URL = "https://recovery.sammohr.dev/";
const DEFAULT_OUT = "recovery-kit";

type Args = {
  out: string;
  pageUrl: string;
  /** Required: a guessed pages.dev address would be printed and never checked. */
  fallbackUrl?: string;
  operator?: string;
  blob: string;
  demo: boolean;
  outGiven: boolean;
};

const USAGE = "usage: kit [--out <dir>] [--page-url <url>] [--fallback-url <url>] " +
  "[--operator <name>] [--blob public/data-keys.enc] [--demo]";

function takeValue(argv: string[], index: number, flag: string): string {
  const value = argv[index + 1];
  if (value === undefined || value.startsWith("-")) throw new Error(`${flag} needs a value`);
  return value;
}

function parseArgs(argv: string[]): Args {
  const args: Args = {
    out: DEFAULT_OUT,
    pageUrl: DEFAULT_PAGE_URL,
    blob: "public/data-keys.enc",
    demo: false,
    outGiven: false,
  };
  for (let index = 0; index < argv.length; index++) {
    const value = argv[index];
    switch (value) {
      case "--out":
        args.out = takeValue(argv, index++, value);
        args.outGiven = true;
        break;
      case "--demo":
        args.demo = true;
        break;
      case "--page-url":
        args.pageUrl = takeValue(argv, index++, value);
        break;
      case "--fallback-url":
        args.fallbackUrl = takeValue(argv, index++, value);
        break;
      case "--operator":
        args.operator = takeValue(argv, index++, value);
        break;
      case "--blob":
        args.blob = takeValue(argv, index++, value);
        break;
      case "--help":
      case "-h":
        console.log(USAGE);
        Deno.exit(0);
        break;
      default:
        throw new Error(`unknown argument: ${value}`);
    }
  }
  return args;
}

function homePath(path: string): string {
  return path.startsWith("~/") ? `${Deno.env.get("HOME") ?? ""}${path.slice(1)}` : path;
}

function resolveOut(path: string): string {
  const resolved = homePath(path).replace(/\/+$/, "");
  const absolute = resolved.startsWith("/") ? resolved : `${Deno.cwd()}/${resolved}`;
  const out = new URL(`file://${absolute}/`);
  const repo = new URL("../../", import.meta.url);
  if (out.href.startsWith(repo.href)) {
    throw new Error("refusing to write plaintext secrets inside the repository");
  }
  return out.pathname;
}

async function writeSecret(path: string, text: string): Promise<void> {
  await Deno.writeTextFile(path, text, { mode: 0o600 });
  await Deno.chmod(path, 0o600).catch(() => undefined); // exFAT and other foreign filesystems
}

function checklist(recipients: string[], values: KitValues): string {
  const names = recipients.map((name) => kitSlug(name)).join(", ");
  const demo = values.demo ? "**DEMO - FAKE VALUES - do not print or use this kit.**\n\n" : "";
  return `# Recovery kit checklist

${demo}Generated for: ${recipients.join(", ")}

The folder holds **plaintext passwords**. Treat it like the letters: print it,
then delete it (or keep it only on an encrypted disk).

## 1. Print

- [ ] \`letter-*.html\` - one per person, two pages: cover and instructions.
- [ ] \`label-*.html\` - drive labels, cut to 70x40 mm.

## 2. Write the two drives

Each drive is exFAT (readable on macOS and Windows) and named after its owner.

- [ ] \`drive-<name>/START-HERE.txt\` goes at the drive root.
- [ ] Eject cleanly, then plug it back in and open \`START-HERE.txt\` once.

## 3. Seal

- [ ] Put one letter + one label + one drive per person.
- [ ] Seal the letter in an envelope, label the envelope with the person's name.
- [ ] Hand over in person; the recipient keeps it sealed until needed.

## 4. Verify before handing over

- [ ] Open \`${values.pageUrl}\` in a browser and unlock it with the recovery password on
  the letter: it must show the account list.
- [ ] On a Mac, open the same page in Chrome and confirm the "Restore everything"
  button appears.
- [ ] Copy \`START-HERE.txt\` off a drive on a machine that is not yours and read it.

## 5. Reprint rules

The media carry the Bitwarden e-mail, its **master password**, the two-step
recovery code, the page URL and the recovery password. Reprint both when:

- the Bitwarden master password or its recovery code changes,
- the recovery password changes (rerun \`deno task blob\` first),
- the page address changes.

Nothing else on the media changes when keys, buckets or paths change: those
live in the encrypted blob behind the recovery password.

Recipients: ${names}
`;
}

async function writeKit(
  out: string,
  recipients: string[],
  valuesFor: (recipient: string) => KitValues,
): Promise<void> {
  await Deno.mkdir(out, { recursive: true, mode: 0o700 });
  await Deno.chmod(out, 0o700).catch(() => undefined);

  const written: string[] = [];
  for (const recipient of recipients) {
    const slug = kitSlug(recipient);
    const values = valuesFor(recipient);
    const driveDir = out + "drive-" + slug + "/";
    await Deno.mkdir(driveDir, { recursive: true, mode: 0o700 });
    await Deno.chmod(driveDir, 0o700).catch(() => undefined);

    await writeSecret(out + "letter-" + slug + ".html", renderLetter(values));
    await writeSecret(out + "label-" + slug + ".html", renderLabel(values));
    await writeSecret(driveDir + "START-HERE.txt", renderStartHere(values));
    written.push(
      out + "letter-" + slug + ".html",
      out + "label-" + slug + ".html",
      driveDir + "START-HERE.txt",
    );
  }

  await writeSecret(out + "CHECKLIST.md", checklist(recipients, valuesFor(recipients[0])));
  written.push(out + "CHECKLIST.md");

  console.log("wrote " + written.length + " file(s) under " + out);
  for (const path of written) console.log("  " + path);
  console.log(
    valuesFor(recipients[0]).demo
      ? "demo: fake values only; nothing here can unlock anything."
      : "plaintext secrets: print the letters, then delete this folder.",
  );
}

function demoValues(args: Args): (recipient: string) => KitValues {
  return (recipient) => ({
    recipient,
    operatorName: "Sam Example",
    bitwardenEmail: "sam@example.com",
    bitwardenPassword: "DEMO-master-password",
    recoveryCode: "DEMO-CODE-1234",
    recoveryPassword: "DEMO-recovery-password",
    pageUrl: args.pageUrl,
    fallbackUrl: args.fallbackUrl ?? "https://demo.pages.dev/",
    demo: true,
  });
}

async function main(): Promise<void> {
  const args = parseArgs(Deno.args);

  if (args.demo) {
    // No prompts and no blob check: a demo exists to inspect the layout and
    // wording before any real secret is typed into this terminal.
    console.log("DEMO: fake values, no prompts, no recovery-password check.");
    const out = resolveOut(
      args.outGiven ? args.out : `${Deno.env.get("TMPDIR") ?? "/tmp"}/recovery-kit-demo`,
    );
    await writeKit(out, ["Alex Example", "Jordan Example"], demoValues(args));
    return;
  }

  if (!args.fallbackUrl) throw new Error("--fallback-url <pages.dev url> is required");
  const fallbackUrl = args.fallbackUrl;
  const out = resolveOut(args.out);
  const operator = args.operator ?? (await promptVisible("Your name: "));
  if (!operator) throw new Error("a name is needed on the letters");

  const recipients: string[] = [];
  while (true) {
    const name = (
      await promptVisible(`Recipient ${recipients.length + 1} (blank when done): `)
    ).trim();
    if (!name) break;
    recipients.push(name);
  }
  if (recipients.length === 0) throw new Error("no recipients");

  console.log("These values are printed on both the letters and the drives.");
  const bitwardenEmail = (await promptVisible("Bitwarden e-mail: ")).trim();
  const bitwardenPassword = await promptHidden("Bitwarden master password: ");
  const recoveryCode = (await promptVisible("Bitwarden two-step recovery code: ")).trim();
  const recoveryPassword = await promptHidden("Recovery password: ");

  const opens = await verifyBlobPassword(args.blob, recoveryPassword);
  if (opens === false) {
    throw new Error(
      `that password does not open ${args.blob}; the letters would be useless. Fix it and rerun`,
    );
  }
  if (opens === null) {
    throw new Error(`${args.blob} is missing; build it with deno task blob before printing a kit`);
  }

  await writeKit(out, recipients, (recipient) => ({
    recipient,
    operatorName: operator,
    bitwardenEmail,
    bitwardenPassword,
    recoveryCode,
    recoveryPassword,
    pageUrl: args.pageUrl,
    fallbackUrl,
  }));
}

main().catch((error: unknown) => {
  console.error(`kit failed: ${error instanceof Error ? error.message : String(error)}`);
  Deno.exit(1);
});
