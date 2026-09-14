#!/usr/bin/env bash
# Shared by host and extension builds so their container identifier cannot drift.
inklet_configure_widget_group() {
  # macOS can block access indefinitely for an unprovisioned ad-hoc identity.
  # Local previews use per-app storage; only signed builds share live data.
  if [[ "${INKLET_SIGN_IDENTITY:--}" == "-" ]]; then
    export INKLET_WIDGET_STORAGE_MODE=local
  else
    export INKLET_WIDGET_STORAGE_MODE=shared
  fi
  if [[ -n "${INKLET_APP_GROUP:-}" ]]; then
    export INKLET_APP_GROUP
    return
  fi
  local identity="${INKLET_SIGN_IDENTITY:--}"
  local team="${INKLET_TEAM_ID:-}"
  if [[ -z "$team" && "$identity" =~ \(([A-Z0-9]{10})\)$ ]]; then
    team="${BASH_REMATCH[1]}"
  fi
  if [[ "$identity" == "-" ]]; then
    # Local ad-hoc builds only; distributed builds use the macOS Team ID form.
    export INKLET_APP_GROUP=group.com.iminklet.portal
  elif [[ "$team" =~ ^[A-Z0-9]{10}$ ]]; then
    export INKLET_APP_GROUP="$team.com.iminklet.mac"
  else
    echo "Set INKLET_TEAM_ID when signing with a certificate hash or a name without its Team ID." >&2
    return 1
  fi
}
