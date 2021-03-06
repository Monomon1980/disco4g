#!/bin/sh
{

# variables
initial_connection_timeout_seconds=20
	
ulogger -s -t uavpal_disco "Huawei USB device detected"
ulogger -s -t uavpal_disco "=== Loading uavpal softmod $(head -1 /data/ftp/uavpal/version.txt |tr -d '\r\n' |tr -d '\n') ==="

disco_fw_version=`grep ro.parrot.build.uid /etc/build.prop | cut -d '-' -f 3`
disco_fw_version_numeric=${disco_fw_version//.}
if [ "$disco_fw_version_numeric" -ge "170" ]; then
	kernel_mods="1.7.0"
else
	kernel_mods="1.4.1"
fi
ulogger -s -t uavpal_disco "... detected Disco firmware version ${disco_fw_version}, trying to use kernel modules compiled for firmware ${kernel_mods}"

ulogger -s -t uavpal_disco "... loading tunnel kernel module (for zerotier)"
insmod /data/ftp/uavpal/mod/${kernel_mods}/tun.ko

ulogger -s -t uavpal_disco "... loading USB modem kernel modules"
insmod /data/ftp/uavpal/mod/${kernel_mods}/usbserial.ko 
insmod /data/ftp/uavpal/mod/${kernel_mods}/usb_wwan.ko
insmod /data/ftp/uavpal/mod/${kernel_mods}/option.ko

ulogger -s -t uavpal_disco "... loading iptables kernel modules (required for security)"
insmod /data/ftp/uavpal/mod/${kernel_mods}/x_tables.ko                  # needed for firmware <=1.4.1 only
insmod /data/ftp/uavpal/mod/${kernel_mods}/ip_tables.ko                 # needed for firmware <=1.4.1 only
insmod /data/ftp/uavpal/mod/${kernel_mods}/iptable_filter.ko            # needed for firmware <=1.4.1 and >=1.7.0
insmod /data/ftp/uavpal/mod/${kernel_mods}/xt_tcpudp.ko                 # needed for firmware <=1.4.1 only

# Security: block incoming connections on the Internet interface
# these connections should only be allowed on Wi-Fi (eth0) and via zerotier (zt*)
ulogger -s -t uavpal_disco "... applying iptables security rules"
ip_block='21 23 51 61 873 8888 9050 44444 67 5353 14551'
for i in $ip_block; do iptables -I INPUT -p tcp -i usb0 --dport $i -j DROP; done

ulogger -s -t uavpal_disco "... running usb_modeswitch to switch Huawei modem into ncm mode"
/data/ftp/uavpal/bin/usb_modeswitch -v 12d1 -p `lsusb |grep "ID 12d1" | cut -f 3 -d \:` --huawei-alt-mode -s 3

until [ -d "/proc/sys/net/ipv4/conf/usb0" ] && [ -c "/dev/ttyUSB0" ]; do usleep 100000; done
ulogger -s -t uavpal_disco "... detected Huawei USB modem in ncm mode"

ulogger -s -t uavpal_disco "... starting connection manager script"
/data/ftp/uavpal/bin/uavpal_connmgr.sh &

ulogger -s -t uavpal_disco "... waiting for public Internet connection"
while true; do
	if ping -c 1 8.8.8.8 >/dev/null 2>&1; then
		ulogger -s -t uavpal_disco "... public Internet connection is up"
		break # break out of loop
	fi
done

ulogger -s -t uavpal_disco "... setting date/time using ntp"
ntpd -n -d -q

ulogger -s -t uavpal_disco "... starting glympse script for GPS tracking"
/data/ftp/uavpal/bin/uavpal_glympse.sh &

if [ -d "/data/lib/zerotier-one/networks.d" ] && [ ! -f "/data/lib/zerotier-one/networks.d/$(head -1 /data/ftp/uavpal/conf/zt_networkid |tr -d '\r\n' |tr -d '\n').conf" ]; then
	ulogger -s -t uavpal_disco "... zerotier config's network ID does not match zt_networkid config - removing zerotier data directory to allow join of new network ID"
	rm -rf /data/lib/zerotier-one 2>/dev/null
fi

ulogger -s -t uavpal_disco "... starting zerotier daemon"
/data/ftp/uavpal/bin/zerotier-one -d

if [ ! -d "/data/lib/zerotier-one/networks.d" ]; then
	ulogger -s -t uavpal_disco "... (initial-)joining zerotier network ID"
	while true
	do
		ztjoin_response=`/data/ftp/uavpal/bin/zerotier-one -q join $(head -1 /data/ftp/uavpal/conf/zt_networkid |tr -d '\r\n' |tr -d '\n')`
		if [ "`echo $ztjoin_response |head -n1 |awk '{print $1}')`" == "200" ]; then
			ulogger -s -t uavpal_disco "... successfully joined zerotier network ID"
			break # break out of loop
		else
			ulogger -s -t uavpal_disco "... ERROR joining zerotier network ID: $ztjoin_response - trying again"
			sleep 1
		fi
	done
fi
ulogger -s -t uavpal_disco "*** idle on LTE ***"
} &
