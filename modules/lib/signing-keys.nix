# Software commit-signing keys, one per GitHub account. The private halves
# live in sops as `github-<account>-signing-key` (personal in common.yaml for
# every host, work in smoreswork.yaml for the work Mac only); the public halves
# are committed so allowed_signers and smortress's forced sandbox login can
# trust them without decrypting anything. Each is registered on its account as
# a signing key only.
{
  personal = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFnHrQhNLmu/LvLXxzaU3JLZyT7JzT/VvJjJPUiiiHYJ";
  work = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG7xy6j09IoZ9p/sZn3Y8Fo0E6q0Z2V5HpU3i3J3sNm3";

}
