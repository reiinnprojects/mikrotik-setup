#!/bin/bash
# Tanay-style hotspot DNS: lokalfi.net must be dynamic (D), not manual static.
# Sourced from mikrotik-apply-portal-network.sh (do not run directly).

remove_manual_lokalfi_net_static() {
  run_ros ':foreach i in=[/ip dns static find where name="lokalfi.net" dynamic=no] do={ /ip dns static remove $i }'
}

refresh_hotspot_portal_dns() {
  if [ "$DRY_RUN" = true ]; then
    printf "%s\n" "${BLUE}[DRY-RUN] Would refresh hotspot portal DNS (hsprof1 + hotspot1 bounce)${NC}"
    return 0
  fi

  remove_manual_lokalfi_net_static
  printf "%s\n" "${BLUE}[INFO] Refreshing hotspot portal DNS (lokalfi.net dynamic D) ...${NC}"
  run_ros '/ip hotspot profile set [find name="hsprof1"] dns-name=lokalfi.net hotspot-address=10.0.0.1'
  run_ros '/ip hotspot disable [find name="hotspot1"]'
  sleep 2
  run_ros '/ip hotspot enable [find name="hotspot1"]'
  sleep 2

  printf "%s\n" "${BLUE}[INFO] DNS static (lokalfi / app):${NC}"
  _run_ssh '/ip dns static print detail where name~"lokalfi"'
}

verify_hotspot_portal_dns() {
  if [ "$DRY_RUN" = true ]; then
    return 0
  fi
  if _run_ssh '/ip dns static print detail where name="lokalfi.net" dynamic=yes' | grep -q 'address=10.0.0.1'; then
    printf "%s\n" "${GREEN}[SUCCESS] lokalfi.net dynamic DNS (10.0.0.1) present.${NC}"
    return 0
  fi
  printf "%s\n" "${RED}[ERROR] lokalfi.net dynamic DNS missing after refresh.${NC}" >&2
  return 1
}
