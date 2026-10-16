# Recovery

The EX6150v2 has a NETGEAR **NMRP** bootloader recovery. A bad flash can almost always be fixed over Ethernet.

## nmrpflash (recommended)

1. Download [nmrpflash](https://github.com/jclehner/nmrpflash/releases) for your OS. On Windows, also install Npcap.
2. Connect the PC directly to the extender's Ethernet port. Set the PC's wired adapter to a static IP such as `10.164.183.253/24`.
3. List the interfaces: `nmrpflash -L`
4. Run the command below, then power-cycle the extender:
   ```
   nmrpflash -i <interface> -f openwrt-…-squashfs-factory.img
   ```
   It uploads the image while the bootloader listens.
5. Wait for "Remote finished" and a reboot.

Use either this project's `factory.img` or an original NETGEAR firmware `.img` from netgear.com to go back to stock.

## Failsafe mode (OpenWrt boots but the config is broken)

1. Power on. When the power LED starts blinking quickly, press and hold the **reset** button for about 2 seconds.
2. Set the PC to a static IP `192.168.1.2/24` and run `ssh root@192.168.1.1` (no password in failsafe).
3. Then either:
   - run `mount_root` and fix things; or
   - run `firstboot -y && reboot` for a factory reset.

## Back to NETGEAR firmware

Download the EX6150v2 firmware from netgear.com. Flash it with nmrpflash (above), or from OpenWrt:

```bash
scp -O EX6150v2-V1.0.x.x.img root@<extender>:/tmp/stock.img
ssh root@<extender> 'sysupgrade -F -n /tmp/stock.img'
```

`-F` forces it, because the stock image has no OpenWrt metadata. If unsure, prefer nmrpflash.
