# Sharif L2TP/IPsec VPN

A simple Bash script to connect to **Sharif University VPN** using **L2TP over IPsec** on ArchLinux.  
This project automates setup and connection steps so you don’t have to manually configure `strongSwan` and `xl2tpd` each time.

---

##  Features

- Connects to Sharif VPN using **L2TP/IPsec** protocol
- One-command `up` and `down` usage
- Handles starting/stopping of required services (`strongswan-starter`, `xl2tpd`)
- Ensures UDP ports `500/4500` are free before starting
- Works on most Linux distributions with systemd (tested on Ubuntu/Debian)

---

## Prerequisites

Before using the script, make sure you have these packages installed:

```bash
sudo apt update
sudo apt install strongswan xl2tpd ppp lsof
