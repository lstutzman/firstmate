#!/usr/bin/env bash
# Builds a disposable lab: marked FM_HOME, project clone, worker copy with pushed head, fake forge gh.
set -eu
ROOT=$1; LAB=$2
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
mkdir -p "$LAB/fakebin" "$LAB/config/ready-evidence" "$LAB/clone" "$LAB/tmux"
git init -q --bare "$LAB/origin.git"
git -C "$LAB/clone" init -q -b main; git -C "$LAB/clone" commit -q --allow-empty -m init
git -C "$LAB/clone" remote add origin "$LAB/origin.git"; git -C "$LAB/clone" push -q origin main
git clone -q "$LAB/origin.git" "$LAB/wt"; git -C "$LAB/wt" checkout -q -b fm/evid
git -C "$LAB/wt" commit -q --allow-empty -m fix; git -C "$LAB/wt" push -q origin fm/evid
git -C "$LAB/wt" fetch -q origin
cat > "$LAB/fakebin/gh" <<'G'
#!/usr/bin/env bash
# forge boundary stand-in: reports an OPEN non-draft PR at FAKE_HEAD; logs calls
printf '%s\n' "$*" >> "$FAKE_GH_LOG"
case " $* " in
  *" --json isDraft "*) echo '{"isDraft":false}' ;;
  *" headRefOid "*) echo "$FAKE_HEAD" ;;
  *" --json body "*) cat "$FAKE_BODY" ;;
  *) exit 1 ;;
esac
G
chmod +x "$LAB/fakebin/gh"
