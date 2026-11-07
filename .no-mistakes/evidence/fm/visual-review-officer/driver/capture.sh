# capture <dir> <salt>: a capture directory with a manifest and three PNGs (salt changes their bytes, i.e. a changed screen).
capture() {
  mkdir -p "$1/shots"
  for n in deal-desktop deal-mobile port-desktop; do printf '\x89PNG\r\n\x1a\n%s-%s' "$n" "$2" > "$1/shots/$n.png"; done
  jq -n '{entries: [
    {key: "/deal-finder|desktop|default", route: "/deal-finder", viewport: "desktop", state: "default", test: "deal.spec.ts", file: "shots/deal-desktop.png"},
    {key: "/deal-finder|mobile|default", route: "/deal-finder", viewport: "mobile", state: "default", test: "deal.spec.ts", file: "shots/deal-mobile.png"},
    {key: "/portfolio|desktop|default", route: "/portfolio", viewport: "desktop", state: "default", test: "port.spec.ts", file: "shots/port-desktop.png"}]}' > "$1/manifest.json"
}
