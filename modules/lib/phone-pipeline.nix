# The phone pipeline's path and naming contract, shared by the host Syncthing folder, the
# kanbei guest's decrypt service and the export tooling under `mobile/`. One file so a
# rename cannot half-land: the host, the guest and the docs all read these names.
#
# The phone is the *trusted* Syncthing peer. It writes the plaintext export tree
# (`sms/`, `health/`, `contacts/`) from its own folder and shares that folder to the
# host with a folder password, so the host stores only ciphertext. Kanbei holds the
# password and decrypts in-VM; the host never has it and cannot read the exports.
let
  # Syncthing folder id; the phone must publish the folder under this id or the
  # declarative host config will not match it.
  folderId = "phone";
  hostFolder = "/var/lib/data/phone-untrusted";
  tag = "phone-untrusted";
  guestMount = "/mnt/kanbei/phone-untrusted";

  # Host-side contract path (sops) and the guest-side copies. The guest stages the
  # contract into the LUKS volume once, so a later boot without the sops file still
  # decrypts.
  passwordContract = "/run/secrets/phone-folder-password";
  guestContract = "/run/kanbei-secrets/phone-folder-password";
  stagedPassword = "/var/lib/kanbei/secrets/phone-folder-password";

  # Decrypted tree and the service's private state, all inside the LUKS volume.
  plaintextDir = "/var/lib/kanbei/phone";
  stateDir = "/var/lib/kanbei/phone-state";
  manifestName = "manifest.json";

  # 16 MiB per decrypted file: a day's NDJSON/JSON export is orders of magnitude
  # smaller, and anything larger is either an unset binary-MMS toggle or not an export.
  maxFileBytes = 16 * 1024 * 1024;

  # Canonical subdirectories in the decrypted tree. SMS Import/Export cannot split its
  # scheduled output across directories, so `contacts-*.json` arrives under `sms/` and
  # the decrypt service routes it to `contacts/`.
  kindDirs = {
    sms = "sms";
    contacts = "contacts";
    health = "health";
  };
in
{
  inherit
    folderId
    hostFolder
    tag
    guestMount
    passwordContract
    guestContract
    stagedPassword
    plaintextDir
    stateDir
    manifestName
    maxFileBytes
    kindDirs
    ;

  # The batch envelope contract Kanbei's inbox reader consumes (#600/#610). The decrypt
  # service is the only producer of `source = "phone"` batches; unlike the ingest VMs it
  # writes them inside the guest, because the phone data arrives over Syncthing rather
  # than through a host writer.
  batch = {
    version = 1;
    source = "phone";
    kind = "batch";
  };

  # Filenames the decrypt service accepts, by canonical kind. The dated names are the
  # ones SMS Import/Export and healthconnect-export produce with retention enabled but
  # datestamp removal off (the documented settings).
  patterns = {
    sms = [
      "^messages-[0-9]{4}-[0-9]{2}-[0-9]{2}\\.zip$"
      "^calls-[0-9]{4}-[0-9]{2}-[0-9]{2}\\.json$"
    ];
    contacts = [ "^contacts-[0-9]{4}-[0-9]{2}-[0-9]{2}\\.json$" ];
    health = [ "^health_[0-9]{4}-[0-9]{2}-[0-9]{2}\\.json$" ];
  };

  # Raw phone-side layout: SMS Import/Export's single scheduled directory is `sms/`,
  # healthconnect-export's output directory is `health/`. Both are still routed by
  # filename, so a file moved between them by hand still lands correctly.
  rawDirs = [
    "sms"
    "health"
    "contacts"
  ];
}
