# Public YubiKey material, one entry per credential and key: the single source for sshd's
# authorized_keys, sudo authorized keys, pam_p11's certificate file and the handle integrity
# check in `key-backup`/`key-restore`. Nothing here is secret, and none is trusted for git
# (the sops keys in modules/lib/signing-keys.nix sign).
# `piv` entries are slot 9a (PIN ONCE, touch NEVER, SSH login); `sudo` entries are
# touch-required, loaded only into the sudo agent (fido2-agent on Linux, sudo-agent on macOS).
# `key` is the path under ~/.config/ssh-sk (piv-k1 vs k1/sudo); `piv` entries also carry the pam_p11 certificate.
{
  piv = [
    {
      key = "piv-k1";
      pubkey = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBJ34zXLDQMZYvFX1q1fEMJ1/uGWvAtQUmu7/lzGqdWJBSAo2RPiYeeCZnA7AIhfwSwCIIv1sJWgopllQifFmZEc= smores piv k1";
      cert = ''
        -----BEGIN CERTIFICATE-----
        MIIBMDCB1qADAgECAhR4tiY5gZCGTZgBnW76TPDWBGR7VzAKBggqhkjOPQQDAjAY
        MRYwFAYDVQQDDA1zbW9yZXMgazEgc3NoMB4XDTI2MTAyODA0MzEzMloXDTM2MTAy
        NTA0MzEzMlowGDEWMBQGA1UEAwwNc21vcmVzIGsxIHNzaDBZMBMGByqGSM49AgEG
        CCqGSM49AwEHA0IABJ34zXLDQMZYvFX1q1fEMJ1/uGWvAtQUmu7/lzGqdWJBSAo2
        RPiYeeCZnA7AIhfwSwCIIv1sJWgopllQifFmZEcwCgYIKoZIzj0EAwIDSQAwRgIh
        AP2V70tKT1Ut7pBSkqaABwU0Ij8cDzrYCsqPCQp4rLWGAiEAvRRusWNxDMLJCxHY
        fjDnco2dt7sdTkliMbd7uzAQ4+c=
        -----END CERTIFICATE-----
      '';
    }
    {
      key = "piv-k2";
      pubkey = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBMcpVmF/c9KcRgBlgRVp/gjrtjuB/+0U1nURKnep+dAt1NtUztpWtwlz7o3drWTHzydNaGZ39uO21TQ3rxMEOBA= smores piv k2";
      cert = ''
        -----BEGIN CERTIFICATE-----
        MIIBLjCB1qADAgECAhREWEi/BU/qWkjMHDuVHYBIYuMIsDAKBggqhkjOPQQDAjAY
        MRYwFAYDVQQDDA1zbW9yZXMgazIgc3NoMB4XDTI2MTAyODA0NDExNVoXDTM2MTAy
        NTA0NDExNVowGDEWMBQGA1UEAwwNc21vcmVzIGsyIHNzaDBZMBMGByqGSM49AgEG
        CCqGSM49AwEHA0IABMcpVmF/c9KcRgBlgRVp/gjrtjuB/+0U1nURKnep+dAt1NtU
        ztpWtwlz7o3drWTHzydNaGZ39uO21TQ3rxMEOBAwCgYIKoZIzj0EAwIDRwAwRAIg
        TygCfMMGUsvQ0b60XDMTJ2Vs8vZgsglCI6bNoUa22XACICcJugvUvzTHxtD2/cvg
        vZ66ytZ/F25nsyjapawuM2u5
        -----END CERTIFICATE-----
      '';
    }
    {
      key = "piv-k3";
      pubkey = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBOJHHVoKZWLnC1EVMVxFv9eNOtkZ+tJFI5TctBvOuzGAfYV0rlm6xv37RF2Pf+8DjUVEnwh9aGYwUsEFOoHUrPM= smores piv k3";
      cert = ''
        -----BEGIN CERTIFICATE-----
        MIIBLzCB1qADAgECAhQNgBLrrrhYYyEckpeZ73CcVx3qmzAKBggqhkjOPQQDAjAY
        MRYwFAYDVQQDDA1zbW9yZXMgazMgc3NoMB4XDTI2MTAyODA0NDUxMVoXDTM2MTAy
        NTA0NDUxMVowGDEWMBQGA1UEAwwNc21vcmVzIGszIHNzaDBZMBMGByqGSM49AgEG
        CCqGSM49AwEHA0IABOJHHVoKZWLnC1EVMVxFv9eNOtkZ+tJFI5TctBvOuzGAfYV0
        rlm6xv37RF2Pf+8DjUVEnwh9aGYwUsEFOoHUrPMwCgYIKoZIzj0EAwIDSAAwRQIg
        Ni881xXm/Zwvln7EcDoCBec6ckzXVF7Ost3WQ/FC3WACIQDWsRYP70YD93Dx0fx5
        VFG+aCbn3QjouLjIkay42iAK/g==
        -----END CERTIFICATE-----
      '';
    }
  ];

  sudo = [
    {
      key = "k1/sudo";
      pubkey = "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIFtNyORYKzj2dpr3AnGla4hMyteHsn1uviR2cBNjrH1HAAAAC3NzaDpzdWRvLWsx smores sudo k1";
    }
    {
      key = "k2/sudo";
      pubkey = "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIHg8qZdcbsoYPfFCntYiqZkKbDOQucuWh1Y9ue8bW1AlAAAAC3NzaDpzdWRvLWsy smores sudo k2";
    }
    {
      key = "k3/sudo";
      pubkey = "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAILGL65a4LnBEjlj+tXGZiiU/94xcd9JPvgUcAaFDoRLbAAAAC3NzaDpzdWRvLWsz smores sudo k3";
    }
  ];
}
