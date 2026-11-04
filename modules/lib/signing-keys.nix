# Software commit-signing keys, one per GitHub account, in sops as `github-<account>-signing-key`
# (personal in common.yaml everywhere, work in smoreswork.yaml for the work Mac only). Public
# halves are committed so allowed_signers and smortress's forced sandbox login trust them without decrypting.
{
  personal = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFnHrQhNLmu/LvLXxzaU3JLZyT7JzT/VvJjJPUiiiHYJ";
  work = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG7xy6j09IoZ9p/sZn3Y8Fo0E6q0Z2V5HpU3i3J3sNm3";
}
