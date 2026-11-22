#!/bin/sh
# Wake-on-LAN (Magic Packet) fuer alle kabelgebundenen Netzwerkkarten einschalten
for n in /sys/class/net/*; do
  i=$(basename "$n")
  [ "$i" = lo ] && continue
  [ "$(cat "$n/type" 2>/dev/null)" = 1 ] || continue
  [ -d "$n/wireless" ] && continue
  ethtool -s "$i" wol g 2>/dev/null && echo "WoL an: $i"
done
exit 0
