# smortress-only. zram alone was full at every host OOM, leaving the kernel no eviction path
# before it killed whole microVMs; the file swap is the escape valve for those spikes.
{
  # Lower than zram's priority, so pages land in compressed RAM first.
  swapDevices = [
    {
      device = "/var/lib/swapfile";
      size = 16384;
      priority = 1;
    }
  ];
}
