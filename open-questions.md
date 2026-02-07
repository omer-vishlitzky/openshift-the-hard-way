# Open Questions

## Firewall / SELinux / networking for HAProxy

Need to verify on a running system:

1. **SELinux**: Does HAProxy need `setsebool -P haproxy_connect_any=1` to bind to 6443/22623? These aren't in the default allowed port list.
2. **firewalld**: Do `firewall-cmd --zone=libvirt --add-port=...` rules survive a firewalld restart? Should we use `--permanent`?
3. **firewalld vs iptables**: Does firewalld restart wipe the NAT/FORWARD iptables rules added in Step 2? If so, need to persist them or use firewalld native rules instead.
4. **RHCOS VMs**: Does RHCOS have any firewall that blocks inbound ports (6443, 2379, 2380, 10250, etc.)? Probably not — RHCOS doesn't run firewalld by default — but should verify.
