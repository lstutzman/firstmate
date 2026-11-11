#!/usr/bin/env bash
# fm-evidence-secrets.sh - find and redact secret-bearing URLs in evidence
# files, such as the browser captures a no-mistakes run publishes to the
# orphan no-mistakes/evidence branch. docs/secret-scan.md owns the policy.
#
# Usage:
#   fm-evidence-secrets.sh check <file-or-dir>...
#       Exit 1 and print "<file>:<line>: <parameter>" for every URL whose
#       query string has a parameter named like token, key, secret, auth, sig,
#       password, passwd or credential and a value other than REDACTED. The
#       value is never printed. Exit 0 when none, 2 on a read error.
#   fm-evidence-secrets.sh redact <file-or-dir>...
#       Rewrite those values to REDACTED in place and print how many were
#       rewritten. A file with none is left untouched.
#
# A directory is searched recursively. Binary files are skipped, so a PNG
# capture is not inspected; a URL drawn inside an image is out of reach.
# The parameter-name match is a substring match on purpose (artifact_load_token,
# X-Amz-Signature, api_key), so it can redact a harmless parameter such as
# keyword; that costs a little evidence detail and never a secret.
# This script cannot hook the publish step (the no-mistakes daemon owns it),
# so it is a check a gate step, a worker or CI runs, not an enforcement point.
set -u

MODE=${1:-}
case "$MODE" in
check | redact) shift ;;
-h | --help)
  sed -n '2,/^set -u/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
  exit 0
  ;;
*)
  echo "usage: fm-evidence-secrets.sh check|redact <file-or-dir>..." >&2
  exit 2
  ;;
esac
[ "$#" -ge 1 ] || {
  echo "usage: fm-evidence-secrets.sh $MODE <file-or-dir>..." >&2
  exit 2
}
command -v perl >/dev/null 2>&1 || {
  echo "fm-evidence-secrets: perl is required" >&2
  exit 2
}

files=()
for target in "$@"; do
  if [ -d "$target" ]; then
    while IFS= read -r -d '' f; do files+=("$f"); done < <(find "$target" -type f -print0)
  elif [ -f "$target" ]; then
    files+=("$target")
  else
    echo "fm-evidence-secrets: not a file or directory: $target" >&2
    exit 2
  fi
done
[ "${#files[@]}" -gt 0 ] || exit 0

perl -e '
use strict;
use warnings;
my $mode = shift @ARGV;
my $name = qr/[\w.\-]*(?:token|key|secret|auth|sig|password|passwd|credential)[\w.\-]*/i;
my ($status, $total) = (0, 0);
for my $f (@ARGV) {
  next unless -T $f;
  open(my $in, "<:raw", $f) or do { print STDERR "fm-evidence-secrets: cannot read $f\n"; $status = 2; next };
  my @lines = <$in>;
  close $in;
  for my $i (0 .. $#lines) {
    $lines[$i] =~ s{(https?://[^\s"\x27<>`)\]\\]+)}{
      my $url = $1;
      while ($url =~ /[?&;]($name)=(?!REDACTED(?:[&#]|\z))[^&#\s]+/g) {
        $total++;
        print "$f:" . ($i + 1) . ": $1\n" if $mode eq "check";
      }
      $url =~ s/([?&;]$name=)(?!REDACTED(?:[&#]|\z))[^&#\s]+/${1}REDACTED/g if $mode eq "redact";
      $url;
    }ge;
  }
  next unless $mode eq "redact";
  # Rewrite only a file whose URLs changed: compare against a fresh read.
  open(my $re, "<:raw", $f) or next;
  local $/;
  my $before = <$re>;
  close $re;
  my $after = join("", @lines);
  next if $before eq $after;
  open(my $out, ">:raw", "$f.fm-redact.$$") or do { print STDERR "fm-evidence-secrets: cannot write $f\n"; $status = 2; next };
  print $out $after;
  close $out;
  my $mode_bits = (stat $f)[2] & 07777;
  chmod $mode_bits, "$f.fm-redact.$$";
  rename "$f.fm-redact.$$", $f or do { print STDERR "fm-evidence-secrets: cannot replace $f\n"; $status = 2 };
}
if ($mode eq "redact") { print "redacted $total secret-bearing URL parameter(s)\n"; exit $status; }
exit($status || ($total ? 1 : 0));
' "$MODE" "${files[@]}"
