[Unit]
Description=eks-killer bind master EIP to loopback (hairpin-free local API access)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=-/usr/sbin/ip addr add ${eip_public_ip}/32 dev lo

[Install]
WantedBy=multi-user.target
