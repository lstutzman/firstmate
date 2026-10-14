# Independent oracle: docs/configuration.md "Pooled Claude quota" rule, computed from a raw cpa-usage-axi table.
import math, sys
lines = open(sys.argv[1]).read().split('\n')
head = next(i for i, l in enumerate(lines) if l.startswith('accounts[') and l.endswith('}:'))
fields = lines[head][lines[head].index('{') + 1:lines[head].index('}')].split(',')
rows = []
for l in lines[head + 1:]:
    if not l.startswith('  '): break
    rows.append(dict(zip(fields, l[2:].split(','))))
rem = []
for r in rows:
    if r['provider'] != 'claude': continue
    u5 = float(r['used_5h']) if r['used_5h'] != '' else 0.0
    u7 = float(r['used_7d']) if r['used_7d'] != '' else 0.0
    rem.append(min(max(1 - max(u5, u7), 0.0), 1.0))
bp = math.floor(sum(rem) / len(rem) * 10000 + 0.5)
fmt = lambda x: repr(x)[:-2] if repr(x).endswith('.0') else repr(x)
print(fmt(bp / 100), fmt(bp / 10000), 'exhausted_now' if all(x == 0 for x in rem) else 'through_reset', len(rem), ' '.join(fmt(round(x, 4)) for x in rem))
