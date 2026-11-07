# Page check 2026-11-07T12

5 open finding(s), 0 new.

Coverage: local-jev not found at /nonexistent/jev.py, so duplicates are found by fingerprint only
- Linear: writes linear; 0 of 450 call(s) used.
- Linear: local-jev not found at /nonexistent/jev.py, so duplicates are found by fingerprint only
- Patterns: 4 known, 4 new this run.
- Pattern: Anti-pattern: page-old on Velocity audit (route: page owner: restore the page's feed). Safe form: page owner: restore the page's feed (x1)
- Pattern: Anti-pattern: shown-after-done on Captain's Log (route: cl-keeper: close the card; fix the source that re-raises it). Safe form: cl-keeper: close the card; fix the source that re-raises it (x1)
- Pattern: Anti-pattern: page-old on Business health (route: page owner: fix the feed). Safe form: page owner: fix the feed (x1)
- Pattern: Anti-pattern: page-old on Runs job stripe-billing-sync (route: page owner: fix the job). Safe form: page owner: fix the job (x1)
- Memory capture needed (tags pattern + project): the office captures these 4 line(s) from `patterns` in the digest json.
- [page-old] Business health - business-health: Business health: not updated for 78 hour(s) (evidence: normal gap is 36 hour(s); last publish 2026-11-04 06:00Z) -> page owner: fix the feed [Linear PC-102, found 1, score 2.0]
- [page-old] Runs - stripe-billing-sync: Billing sync is failing (evidence: officer bosun: health failing, next due 2026-11-08T00:00:00Z) -> page owner: fix the job [Linear PC-103, found 1, score 2.0]
- [page-old] Velocity audit - velocity-audit: Velocity audit: never published (evidence: GET /api/velocity-audit was missing) -> page owner: restore the page's feed [Linear PC-101, found 1, score 4.0]
- [shown-after-done] Captain's Log - payments-legal-merge-asks-2026-11-07: Go for production deploy of 1.2.3 and payments merge? (evidence: the app's own record for this card is closed but the page shows it asked) -> cl-keeper: close the card; fix the source that re-raises it [Linear PC-104, found 1, score 2.0]
- [standing-rule] Captain's Log - cleanup:routine-cleanup: Approve deleting 475 stale branches? (evidence: standing rule routine-cleanup settles it: routine clean-up needs no approval (Lee, 2026-10-31)) -> cl-keeper: close the card citing the rule [Linear PC-105, found 1, score 1.0]
