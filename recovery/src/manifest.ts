export type RecoveryItem = {
  title: string;
  /** Item name to search for in the Bitwarden Family Access folder. */
  bitwardenName?: string;
  url?: string;
  notes?: string;
};

export type RecoverySection = {
  id: string;
  title: string;
  description?: string;
  items: RecoveryItem[];
};

export type RecoveryManifest = {
  version: 1;
  updated: string;
  sections: RecoverySection[];
  warnings?: string[];
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
  const titles = new Set<string>();

  for (const section of value.sections) {
    if (!isRecord(section)) {
      errors.push("a section is not an object");
      continue;
    }
    const sectionLabel = isNonEmptyString(section.id) ? section.id : "?";
    if (!isNonEmptyString(section.id)) errors.push("a section is missing an id");
    else if (sectionIds.has(section.id)) errors.push(`duplicate section id: ${section.id}`);
    else sectionIds.add(section.id);
    if (!isNonEmptyString(section.title)) {
      errors.push(`section ${sectionLabel} is missing a title`);
    }
    if (section.description !== undefined && typeof section.description !== "string") {
      errors.push(`section ${sectionLabel} has a non-string description`);
    }
    if (!Array.isArray(section.items) || section.items.length === 0) {
      errors.push(`section ${sectionLabel} has no items`);
      continue;
    }
    for (const item of section.items) {
      if (!isRecord(item)) {
        errors.push("a section item is not an object");
        continue;
      }
      const label = isNonEmptyString(item.title) ? item.title : "?";
      if (!isNonEmptyString(item.title)) errors.push("a section item is missing a title");
      else if (item.title !== item.title.trim()) {
        errors.push(`item title "${item.title}" has surrounding whitespace`);
      } else if (titles.has(item.title)) errors.push(`duplicate item title: ${item.title}`);
      else titles.add(item.title);
      if (item.bitwardenName !== undefined && !isNonEmptyString(item.bitwardenName)) {
        errors.push(`item ${label} has an empty Bitwarden item name`);
      }
      if (item.url !== undefined && (typeof item.url !== "string" || !isHttpUrl(item.url))) {
        errors.push(`item ${label} has a non-http URL`);
      }
      if (item.notes !== undefined && typeof item.notes !== "string") {
        errors.push(`item ${label} has non-string notes`);
      }
    }
  }

  if (value.warnings !== undefined) {
    if (!Array.isArray(value.warnings)) {
      errors.push("warnings must be an array");
    } else {
      for (const warning of value.warnings) {
        if (typeof warning !== "string") errors.push("a warning is not a string");
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

function renderItem(item: RecoveryItem): string {
  const title = escapeHtml(item.title);
  const href = item.url ? escapeHtml(item.url) : "";
  const name = item.url
    ? `<a class="account-name" href="${href}" target="_blank" rel="noreferrer noopener">${title}</a>`
    : `<span class="account-name">${title}</span>`;
  const itemName = item.bitwardenName ? escapeHtml(item.bitwardenName) : "";
  const credential = item.bitwardenName
    ? `<span class="account-credential" title="Bitwarden item"><span class="sr-only">Bitwarden item: </span><code>${itemName}</code></span>`
    : "";
  const notes = item.notes ? `<p class="account-notes">${escapeHtml(item.notes)}</p>` : "";
  return `<li class="account-row"><div class="account-top">${name}${credential}</div>${notes}</li>`;
}

export function renderManifest(manifest: RecoveryManifest): string {
  const errors = validateManifest(manifest);
  if (errors.length > 0) throw new Error(`invalid manifest: ${errors.join(", ")}`);

  const updatedDate = escapeHtml(manifest.updated);
  const updated =
    `<p class="updated">Updated <time datetime="${updatedDate}">${updatedDate}</time></p>`;

  const warnings = (manifest.warnings ?? [])
    .map((warning) => `<li>${escapeHtml(warning)}</li>`)
    .join("");
  const warningBlock = warnings
    ? `<aside class="notice" role="note"><p class="notice-title">Before you start</p><ul>${warnings}</ul></aside>`
    : "";

  const sections = manifest.sections
    .map((section) => {
      const id = `manifest-section-${escapeHtml(section.id)}`;
      const items = section.items.map(renderItem).join("\n");
      const description = section.description
        ? `<p class="panel-sub">${escapeHtml(section.description)}</p>`
        : "";
      return `<section class="panel" id="${id}" aria-labelledby="${id}-title">
  <header class="panel-head">
    <h2 id="${id}-title">${escapeHtml(section.title)}</h2>
    ${description}
  </header>
  <ul class="account-list">${items}</ul>
</section>`;
    })
    .join("\n");

  return `${updated}\n${warningBlock}\n${sections}`;
}
