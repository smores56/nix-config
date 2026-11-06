export type FamilyAccessItem = {
  faId: string;
  title: string;
  bitwardenName: string;
  bitwardenUuid?: string;
  url?: string;
  notes?: string;
  required?: boolean;
  recovery?: boolean;
};

export type FamilyAccessSection = {
  id: string;
  title: string;
  description?: string;
  items: FamilyAccessItem[];
};

export type FamilyAccessContact = {
  name: string;
  role: string;
  contact?: string;
};

export type FamilyAccessManifest = {
  version: 1;
  updated: string;
  sections: FamilyAccessSection[];
  warnings?: string[];
  contacts?: FamilyAccessContact[];
};

function isNonEmptyString(value: unknown): value is string {
  return typeof value === "string" && value.trim().length > 0;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isHttpUrl(value: string): boolean {
  try {
    const url = new URL(value);
    return url.protocol === "http:" || url.protocol === "https:";
  } catch {
    return false;
  }
}

export function validateManifest(value: unknown): string[] {
  const errors: string[] = [];
  if (!isRecord(value)) return ["manifest must be an object"];
  if (value.version !== 1) errors.push("unsupported manifest version");
  if (!isNonEmptyString(value.updated)) errors.push("updated is missing");
  if (!Array.isArray(value.sections) || value.sections.length === 0) {
    return [...errors, "sections are missing"];
  }

  const sectionIds = new Set<string>();
  const faIds = new Set<string>();

  for (const section of value.sections) {
    if (!isRecord(section)) {
      errors.push("a section is not an object");
      continue;
    }
    if (!isNonEmptyString(section.id)) errors.push("a section is missing an id");
    else if (sectionIds.has(section.id)) errors.push(`duplicate section id: ${section.id}`);
    else sectionIds.add(section.id);
    if (!isNonEmptyString(section.title)) {
      errors.push(`section ${isNonEmptyString(section.id) ? section.id : "?"} is missing a title`);
    }
    if (section.description !== undefined && typeof section.description !== "string") {
      errors.push(`section ${isNonEmptyString(section.id) ? section.id : "?"} has a non-string description`);
    }
    if (!Array.isArray(section.items)) {
      errors.push(`section ${isNonEmptyString(section.id) ? section.id : "?"} is missing items`);
      continue;
    }
    for (const item of section.items) {
      if (!isRecord(item)) {
        errors.push("a section item is not an object");
        continue;
      }
      if (!isNonEmptyString(item.faId)) errors.push("a section item is missing fa_id");
      else if (faIds.has(item.faId)) errors.push(`duplicate fa_id: ${item.faId}`);
      else faIds.add(item.faId);
      if (!isNonEmptyString(item.title)) {
        errors.push(`item ${isNonEmptyString(item.faId) ? item.faId : "?"} is missing a title`);
      }
      if (!isNonEmptyString(item.bitwardenName)) {
        errors.push(`item ${isNonEmptyString(item.faId) ? item.faId : "?"} is missing a Bitwarden item name`);
      }
      if (item.url !== undefined && (typeof item.url !== "string" || !isHttpUrl(item.url))) {
        errors.push(`item ${isNonEmptyString(item.faId) ? item.faId : "?"} has a non-http URL`);
      }
      if (item.notes !== undefined && typeof item.notes !== "string") {
        errors.push(`item ${isNonEmptyString(item.faId) ? item.faId : "?"} has non-string notes`);
      }
      if (item.required !== undefined && typeof item.required !== "boolean") {
        errors.push(`item ${isNonEmptyString(item.faId) ? item.faId : "?"} has a non-boolean required flag`);
      }
      if (item.recovery !== undefined && typeof item.recovery !== "boolean") {
        errors.push(`item ${isNonEmptyString(item.faId) ? item.faId : "?"} has a non-boolean recovery flag`);
      }
      if (item.bitwardenUuid !== undefined && typeof item.bitwardenUuid !== "string") {
        errors.push(`item ${isNonEmptyString(item.faId) ? item.faId : "?"} has a non-string Bitwarden UUID`);
      }
    }
  }

  if (value.warnings !== undefined) {
    if (!Array.isArray(value.warnings)) errors.push("warnings must be an array");
    else for (const warning of value.warnings) {
      if (typeof warning !== "string") errors.push("a warning is not a string");
    }
  }
  if (value.contacts !== undefined) {
    if (!Array.isArray(value.contacts)) errors.push("contacts must be an array");
    else for (const contact of value.contacts) {
      if (!isRecord(contact)) {
        errors.push("a contact is not an object");
        continue;
      }
      if (!isNonEmptyString(contact.name)) errors.push("a contact is missing a name");
      if (!isNonEmptyString(contact.role)) errors.push("a contact is missing a role");
      if (contact.contact !== undefined && typeof contact.contact !== "string") {
        errors.push("a contact has a non-string contact");
      }
    }
  }
  return errors;
}

function escapeHtml(value: unknown): string {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

export function renderManifest(manifest: FamilyAccessManifest): string {
  const errors = validateManifest(manifest);
  if (errors.length > 0) throw new Error(`invalid manifest: ${errors.join(", ")}`);

  const updated = `<p class="updated">Updated <time datetime="${escapeHtml(manifest.updated)}">${escapeHtml(manifest.updated)}</time></p>`;

  const sections = manifest.sections
    .map((section) => {
      const items = section.items
        .map((item) => {
          const title = escapeHtml(item.title);
          const credential = escapeHtml(item.bitwardenName);
          const link = item.url
            ? `<a class="item-link" href="${escapeHtml(item.url)}" rel="noreferrer">Open</a>`
            : "";
          const notes = item.notes ? `<p class="item-notes">${escapeHtml(item.notes)}</p>` : "";
          const badges = [
            item.recovery ? '<span class="badge">recovery</span>' : "",
            item.required ? '<span class="badge">required</span>' : "",
          ]
            .filter(Boolean)
            .join("");
          return `<li class="item" data-fa-id="${escapeHtml(item.faId)}">
  <div class="item-head"><span class="item-title">${title}</span>${badges}</div>
  <p class="item-credential">Bitwarden: <code>${credential}</code></p>
  ${notes}${link}
</li>`;
        })
        .join("\n");
      const description = section.description
        ? `<p class="section-description">${escapeHtml(section.description)}</p>`
        : "";
      return `<section class="card" id="manifest-section-${escapeHtml(section.id)}">
  <h2>${escapeHtml(section.title)}</h2>
  ${description}
  <ul class="items">${items}</ul>
</section>`;
    })
    .join("\n");

  const warnings = (manifest.warnings ?? [])
    .map((warning) => `<li>${escapeHtml(warning)}</li>`)
    .join("");
  const warningBlock = warnings
    ? `<aside class="warning" role="note"><h2>Before you start</h2><ul>${warnings}</ul></aside>`
    : "";

  const contacts = (manifest.contacts ?? [])
    .map(
      (contact) =>
        `<li><strong>${escapeHtml(contact.name)}</strong> - ${escapeHtml(contact.role)}${
          contact.contact ? `<br><span>${escapeHtml(contact.contact)}</span>` : ""
        }</li>`,
    )
    .join("");
  const contactBlock = contacts
    ? `<section class="card" id="manifest-contacts"><h2>Contacts</h2><ul class="contacts">${contacts}</ul></section>`
    : "";

  return `${updated}\n${warningBlock}\n${sections}\n${contactBlock}`;
}
