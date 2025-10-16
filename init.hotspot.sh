  #!/system/bin/sh
  LOG=/data/local/tmp/hotspot_boot.log
  CONF=/data/local/hostapd.conf
  RUND=/data/local/tmp/hotspot
  mkdir -p "$RUND"

  {
  echo "----- $(date) [hotspot ap0 + dhcp/nat] -----"

  # Keep HAL + wificond + supplicant alive (chipset needs them)

  svc wifi enable
  setprop ctl.start vendor.wifi_hal_legacy
  setprop ctl.start wificond
  setprop ctl.start wpa_supplicant
  sleep 2

  # Ensure ap0 exists (create if missing)

  IF=ap0
  if [ ! -d /sys/class/net/ap0 ] && command -v iw >/dev/null 2>&1; then
  iw dev wlan0 interface add ap0 type __ap 2>>"$LOG" || true
  fi
  [ -d /sys/class/net/ap0 ] || IF=wlan0

  # Ensure hostapd.conf targets IF and has channel/country

  if grep -q '^interface=' "$CONF" 2>/dev/null; then
  sed -i "s/^interface=.*/interface=$IF/" "$CONF"
  else
  echo "interface=$IF" >> "$CONF"
  fi
  grep -q '^channel=' "$CONF" || echo "channel=6" >> "$CONF"
  grep -q '^country_code=' "$CONF" || echo "country_code=IL" >> "$CONF"
  chown wifi:wifi "$CONF"; chmod 660 "$CONF"

  # Start hostapd (logs in logcat); assign AP IP

  ip link set "$IF" up 2>>"$LOG" || true
  pkill -f 'hostapd .*hostapd.conf' 2>/dev/null
  /vendor/bin/hw/hostapd -d "$CONF" >>"$LOG" 2>&1 &
  sleep 2
  ip addr add 192.168.50.1/24 dev "$IF" 2>>"$LOG" || true
  ip link set "$IF" up 2>>"$LOG" || true


  # --- LAN route + policy rules (so AP traffic always routes correctly) ---
  ip route replace 192.168.50.0/24 dev "$IF" src 192.168.50.1 proto static scope link
  ip rule add iif "$IF" lookup main pref 100 2>/dev/null || true
  ip rule add from 192.168.50.0/24 lookup main pref 101 2>/dev/null || true

  # --- Relax rp_filter (some ROMs drop replies otherwise) ---
  echo 0 > /proc/sys/net/ipv4/conf/"$IF"/rp_filter
  echo 0 > /proc/sys/net/ipv4/conf/all/rp_filter
  echo 0 > /proc/sys/net/ipv4/icmp_echo_ignore_all

  # --- Minimal firewall to reach services on the box (HTTP/HTTPS + ping) ---
  /system/bin/iptables -C INPUT -i "$IF" -p icmp -j ACCEPT 2>/dev/null || \
  /system/bin/iptables -I INPUT 1 -i "$IF" -p icmp -j ACCEPT
  for P in 80 8080 443; do
    /system/bin/iptables -C INPUT -i "$IF" -p tcp --dport $P -j ACCEPT 2>/dev/null || \
    /system/bin/iptables -I INPUT 1 -i "$IF" -p tcp --dport $P -j ACCEPT
  done
  # Common Android OEM chains (if they exist)
  for CH in tetherctrl_csi_INPUT fw_INPUT oem_in oem_fwd; do
    /system/bin/iptables -S "$CH" >/dev/null 2>&1 && \
    (/system/bin/iptables -C "$CH" -i "$IF" -p tcp -m multiport --dports 80,8080,443 -j ACCEPT 2>/dev/null || \
     /system/bin/iptables -I "$CH" 1 -i "$IF" -p tcp -m multiport --dports 80,8080,443 -j ACCEPT)
  done


  # DHCP via dnsmasq (if available)

  DNSMASQ="/data/local/dnsmasq"

  [ -f "$RUND/dnsmasq.pid" ] && kill "$(cat "$RUND/dnsmasq.pid")" 2>/dev/null || true
  pkill -f "[d]nsmasq.*--interface=$IF" 2>/dev/null

  if [ -n "$DNSMASQ" ]; then
  "$DNSMASQ" \
  --no-resolv --no-hosts \
  --bind-interface --interface="$IF" \
  --dhcp-authoritative \
  --dhcp-range=192.168.50.10,192.168.50.250,12h \
  --dhcp-option=3,192.168.50.1 \
  --dhcp-option=6,192.168.50.1,192.168.50.1 \
  --dhcp-leasefile="$RUND/dnsmasq.leases" \
  --pid-file="$RUND/dnsmasq.pid" >>"$LOG" 2>&1 &
  echo "dnsmasq started on $IF" >>"$LOG"
  else
  echo "dnsmasq NOT FOUND; clients need static IPs" >>"$LOG"
  fi

  # NAT to WAN (eth0 or default route dev)

  WAN_IF="$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')"
  [ -z "$WAN_IF" ] && [ -d /sys/class/net/eth0 ] && WAN_IF=eth0

  echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null

  if [ -n "$WAN_IF" ]; then

  # Masquerade + forwarding (idempotent)

  iptables -w -t nat -C POSTROUTING -o "$WAN_IF" -j MASQUERADE 2>/dev/null || \
  iptables -t nat -A POSTROUTING -o "$WAN_IF" -j MASQUERADE
  iptables -C FORWARD -i "$IF" -o "$WAN_IF" -j ACCEPT 2>/dev/null || \
  iptables -A FORWARD -i "$IF" -o "$WAN_IF" -j ACCEPT
  iptables -C FORWARD -i "$WAN_IF" -o "$IF" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
  iptables -w -A FORWARD -i "$WAN_IF" -o "$IF" -m state --state ESTABLISHED,RELATED -j ACCEPT

  iptables -C INPUT  -i "$IF" -p udp --dport 67 -j ACCEPT 2>/dev/null || iptables -A INPUT  -i "$IF" -p udp --dport 67 -j ACCEPT
  iptables -C OUTPUT -o "$IF" -p udp --sport 67 -j ACCEPT 2>/dev/null || iptables -A OUTPUT -o "$IF" -p udp --sport 67 -j ACCEPT
  iptables -C INPUT  -i "$IF" -p udp --sport 68 -j ACCEPT 2>/dev/null || iptables -A INPUT  -i "$IF" -p udp --sport 68 -j ACCEPT
  iptables -C OUTPUT -o "$IF" -p udp --dport 68 -j ACCEPT 2>/dev/null || iptables -A OUTPUT -o "$IF" -p udp --dport 68 -j ACCEPT

  # Allow incoming HTTP on port 80 (from your hotspot clients)
  iptables -I INPUT -i $IF -p tcp --dport 80 -j ACCEPT

  echo "NAT enabled via $WAN_IF" >>"$LOG"
  else
  echo "No WAN detected; AP will be LAN-only" >>"$LOG"
  fi

  ip -o addr show "$IF" >>"$LOG" 2>&1
  echo "AP + DHCP/NAT ready on IF=$IF" >>"$LOG"
  } >>"$LOG" 2>&1

# --- External volumes: detect and bind to stable paths (/storage/SD, /storage/USB) ---
{
  SD_ID=""
  USB_ID=""
  FIRST_ID=""
  CANDS=""

  # Parse /proc/mounts for /mnt/media_rw/<ID> mounts (Android external storage)
  while read -r DEV MP FS OPTS REST; do
    case "$MP" in
      /mnt/media_rw/*)
        ID="${MP##*/}"
        # unique candidates list
        echo " $CANDS " | grep -q " $ID " || CANDS="$CANDS $ID"
        [ -z "$FIRST_ID" ] && FIRST_ID="$ID"
        # Heuristics: mmc (major 179) → SD, scsi (major 8) → USB
        echo "$DEV" | grep -q '179,' && [ -z "$SD_ID" ] && SD_ID="$ID"
        echo "$DEV" | grep -q '8,'   && [ -z "$USB_ID" ] && USB_ID="$ID"
        ;;
    esac
  done < /proc/mounts

  # Fallbacks if heuristics didn’t assign
  if [ -z "$SD_ID" ] && [ -n "$FIRST_ID" ]; then SD_ID="$FIRST_ID"; fi
  if [ -z "$USB_ID" ]; then
    for ID in $CANDS; do
      [ "$ID" != "$SD_ID" ] && { USB_ID="$ID"; break; }
    done
  fi

  SD_SRC=""; USB_SRC=""
  [ -n "$SD_ID" ]  && SD_SRC="/storage/$SD_ID"
  [ -n "$USB_ID" ] && USB_SRC="/storage/$USB_ID"

  SD_DST="/storage/SD"
  USB_DST="/storage/USB"
  mkdir -p "$SD_DST" "$USB_DST"

  bind_or_link() {
    SRC="$1"; DST="$2"; NAME="$3"
    if [ -n "$SRC" ] && [ -d "$SRC" ]; then
      if ! grep -q " $DST " /proc/mounts 2>/dev/null; then
        if mount -o bind "$SRC" "$DST" 2>>"$LOG"; then
          echo "[drives] $NAME bound: $SRC -> $DST" >>"$LOG"
        else
          # Fallback to symlink if bind is blocked by SELinux
          rm -f "$DST" 2>/dev/null; rmdir "$DST" 2>/dev/null || true
          ln -s "$SRC" "$DST" 2>>"$LOG" && echo "[drives] $NAME linked: $SRC -> $DST" >>"$LOG" || \
          echo "[drives] WARN: could not bind or link $SRC -> $DST" >>"$LOG"
        fi
      else
        echo "[drives] $NAME already mounted at $DST" >>"$LOG"
      fi
    else
      echo "[drives] WARN: $NAME source missing: $SRC" >>"$LOG"
    fi
  }

  bind_or_link "$SD_SRC"  "$SD_DST"  "SD"
  bind_or_link "$USB_SRC" "$USB_DST" "USB"

  # Persist info
  {
    echo "SD_ID=$SD_ID"; echo "USB_ID=$USB_ID"
    echo "SD_SRC=$SD_SRC"; echo "USB_SRC=$USB_SRC"
    echo "CANDS=$CANDS"; echo "FIRST_ID=$FIRST_ID"
  } > /data/local/drives.env 2>/dev/null || true
} >>"$LOG" 2>&1

### --- Lighttpd + Python CGI (Termux) --------------------------------------

# Paths (adjust if you want different locations)
LIGHTTPD_BIN="/data/local/lighttpd"
LIGHTTPD_MODDIR="/data/local/lighttpd_lib"
LIGHTTPD_CONF="/data/local/lighttpd.conf"
LIGHTTPD_PID="/data/local/lighttpd.pid"
LIGHTTPD_ERR="/data/local/lighttpd.error.log"
LIGHTTPD_ACC="/data/local/lighttpd.access.log"
LIGHTTPD_RUN="/data/local/lighttpd.run.log"

# Web root and Python
# Prefer stable SD mount as web root; fallback to first detected external, else keep previous path
if [ -d /storage/SD ]; then
  WWW_ROOT="/storage/SD"
elif . /data/local/drives.env 2>/dev/null && [ -n "$FIRST_ID" ] && [ -d "/storage/$FIRST_ID" ]; then
  WWW_ROOT="/storage/$FIRST_ID"
else
  WWW_ROOT="/storage/0F11-2655"
fi

PY3="/data/data/com.termux/files/usr/bin/python3"

# Bail if binary missing
if [ ! -x "$LIGHTTPD_BIN" ]; then
  echo "[hotspot] lighttpd not found at $LIGHTTPD_BIN" >> "$LIGHTTPD_RUN"
else
  # Make sure log dir exists
  mkdir -p /data/local
  touch "$LIGHTTPD_ERR" "$LIGHTTPD_ACC" "$LIGHTTPD_RUN"

  # Stop any previous instance we started
  if [ -f "$LIGHTTPD_PID" ]; then
    kill "$(cat "$LIGHTTPD_PID")" 2>/dev/null || true
    rm -f "$LIGHTTPD_PID"
  fi
  # Fallback kill by conf path (only our instance)
  pkill -f "[l]ighttpd.*-f $LIGHTTPD_CONF" 2>/dev/null || true

  rm -f "$LIGHTTPD_CONF"

  # Create a minimal config if missing
  if [ ! -f "$LIGHTTPD_CONF" ]; then
    cat > "$LIGHTTPD_CONF" <<'EOF'
server.modules = (
  "mod_access",
  "mod_accesslog",
  "mod_alias",
  "mod_cgi",
  "mod_dirlisting",
  "mod_staticfile"
)

# Listen on all interfaces, port 80 (change if you want 80)
server.bind = "0.0.0.0"
server.port = 80

# Document root (set below via envsubst-like sed)
server.document-root = "__WWW_ROOT__"

# Index files and optional directory listing
index-file.names = ( "index.html", "index.htm", "index.py" )
dir-listing.activate = "enable"

# Logs & pid
server.errorlog = "__LIGHTTPD_ERR__"
accesslog.filename = "__LIGHTTPD_ACC__"
server.pid-file = "__LIGHTTPD_PID__"

server.upload-dirs = ( "/data/local/tmp" )

# Don’t chroot; keep user as root so it can read /storage/* (many Android mounts restrict other uids)
#server.username = "root"
#server.groupname = "root"

# MIME
mimetype.assign = ( ".html" => "text/html",
                    ".htm"  => "text/html",
                    ".css"  => "text/css",
                    ".js"   => "application/javascript",
                    ".png"  => "image/png",
                    ".jpg"  => "image/jpeg",
                    ".jpeg" => "image/jpeg",
                    ".gif"  => "image/gif",
                    ".svg"  => "image/svg+xml",
                    ".txt"  => "text/plain",
                    ".json" => "application/json" )

# Enable Python CGI for .py
# cgi.assign = ( ".py" => "__PY3__" )

# Security/CGI tweaks
# Require execute bit on scripts (recommended). Ensure your .py files are +x.
#cgi.execute-x-only = "enable"

# Reduce verbose dir-listing info
server.dir-listing = "enable"
server.max-keep-alive-requests = 4
EOF

    # Fill placeholders
    sed -i \
      -e "s#__WWW_ROOT__#${WWW_ROOT}#g" \
      -e "s#__LIGHTTPD_ERR__#${LIGHTTPD_ERR}#g" \
      -e "s#__LIGHTTPD_ACC__#${LIGHTTPD_ACC}#g" \
      -e "s#__LIGHTTPD_PID__#${LIGHTTPD_PID}#g" \
      -e "s#__PY3__#${PY3}#g" \
      "$LIGHTTPD_CONF"
  fi

  # Sanity checks
  if [ ! -d "$WWW_ROOT" ]; then
    echo "[hotspot] WARN: WWW root $WWW_ROOT not found" >> "$LIGHTTPD_RUN"
    mkdir -p "$WWW_ROOT" 2>/dev/null || true
  fi

  # Start lighttpd
  echo "[hotspot] starting lighttpd: $LIGHTTPD_BIN -f $LIGHTTPD_CONF -m $LIGHTTPD_MODDIR" >> "$LIGHTTPD_RUN"
  "$LIGHTTPD_BIN" -f "$LIGHTTPD_CONF" -m "$LIGHTTPD_MODDIR" >>"$LIGHTTPD_RUN" 2>&1 &

  # Optional: quick wait and report status
  sleep 1
  if [ -f "$LIGHTTPD_PID" ] && kill -0 "$(cat "$LIGHTTPD_PID")" 2>/dev/null; then
    echo "[hotspot] lighttpd up (pid $(cat "$LIGHTTPD_PID")), root=$WWW_ROOT" >> "$LIGHTTPD_RUN"
  else
    echo "[hotspot] ERROR: lighttpd failed to start, see $LIGHTTPD_ERR / $LIGHTTPD_RUN" >> "$LIGHTTPD_RUN"
  fi
fi
### -------------------------------------------------------------------------
