# Offline Android TV Media Server

An offline media server for an Android TV box. It creates a Wi‑Fi hotspot at 192.168.50.1 and serves Shows, Movies, and Music from external storage. The box can still be used as a regular Android TV, based on the Mortal T1 TVBOX
Based on the idea of Pocket Nomad

## Features
- Hotspot at 192.168.50.1 with DHCP
- Local web UI (tv.html) for Shows, Movies, and Music
- Direct playback via lighttpd; SRT subtitles auto‑detected and toggleable
- Works from SD/USB without changing your folder structure
- Optional DNS hijack to resolve all names to the box (captive‑portal style)

## Quick start
1) Copy the contents of `SD/` to the root of your external drive on the device (e.g., `/storage/<ID>`).
2) Run `upload.sh` to start the hotspot, DNS, and web server.
3) restart the box
4) Connect a client
4) From a connected client, open: `http://192.168.50.1/tv.html`.

## Use as a regular Android TV
- The hotspot/web server runs alongside normal Android apps.
- Stop the script or disable the hotspot to use the box purely as a standard Android TV.

## Repo layout
- `SD/`: Web UI (tv.html, tv-shows.html, tv-movies.html, tv-music.html, assets)
- `init.hotspot.sh`: Hotspot + dnsmasq + iptables + lighttpd startup
- `lighttpd.conf`, `dnsmasq/`, etc.: Server configs and helpers

## License

Licensed under the Apache License, Version 2.0. See `LICENSE` for terms. 
Attribution notices are provided in `NOTICE`; please retain them in distributions and derivative works.
