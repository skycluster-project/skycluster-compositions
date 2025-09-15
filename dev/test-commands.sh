sudo ip route show table main 
sudo ip rule show

# for a remote address of 10.0.0.0/19
sudo conntrack -L -s 172.17.0.0/16  | grep 10.0.0.0

sudo tcpdump -i vx-submariner host 10.0.1.205 -vvv


# 1) show neighbor entries on gateway vxlan
ip neigh show dev vx-submariner

# 2) show FDB entries for vx-submariner
sudo bridge fdb show dev vx-submariner || sudo /sbin/bridge fdb show dev vx-submariner

# 3) device details (vxlan id, dstport, local/dst ports)
sudo ip -d link show vx-submariner


sudo iptables -t nat -A POSTROUTING -s 172.17.4.0/24 -d 10.0.0.0/19 -j MASQUERADE


sysctl net.ipv4.ip_forward
sysctl net.ipv4.conf.all.rp_filter net.ipv4.conf.default.rp_filter net.ipv4.conf.ens4.rp_filter
sysctl -w net.ipv4.conf.all.rp_filter=2


# cat /etc/iproute2/rt_tables
# sudo ip route show table 1
# sudo ip route show table main
# sudo ip route show table all
# sudo ip rule show

# table 3003

sudo ip route add 10.17.0.16 dev gkeeefec9d8cb2 table 1
# sudo ip rule del not from all iif ens4 lookup 1
# 240.0.0.0/8 dev vx-submariner proto kernel scope link src 240.17.96.3

# Table 150 does not have a route to this destination so it falls back to default
sudo ip route add 10.17.2.1 dev vx-submariner table 150
sudo ip route add 10.17.2.0/24 dev vx-submariner table 150


sudo ip rule del not iif ens4 lookup 1


sudo ip rule add iif submariner to 10.17.0.0/17 lookup main priority 2100


echo "200 skycluster" | sudo tee -a /etc/iproute2/rt_tables

# add a sample route into table 200 (example: route 10.0.0.0/24 via dev eth0, source 192.0.2.10)
sudo ip route add 10.17.0.0/18 dev vx-submariner table 200 proto static scope link

sudo ip rule add iif submariner to 10.17.0.0/17 lookup skycluster priority 2000

# sudo ip route add 10.17.0.0/17 dev vx-submariner proto static table skycluster