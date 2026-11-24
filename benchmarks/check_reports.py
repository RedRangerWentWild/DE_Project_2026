#!/usr/bin/env python3
"""Checks the timings quoted in the reports against the raw result files.

The brief: "Every number in your reports must match the raw plan files in
benchmarks/results/." This script reads the tables of the reports and
recomputes each number from the files it came from:

  docs/03_baseline_timings.md     the three runs, average and total of all 30 queries
                                  (baseline/<id>.txt, baseline/summary.csv); the averages
                                  and scan types of section 3; the share of R19
  docs/04_optimization_report.md  the headline table; before, after, improvement and
                                  speed-up of all 30 queries and the total; the numbers in
                                  the plan excerpts of section 5 (run 3 of each cited
                                  file); the indexes-only comparison; write overhead, from
                                  the plans and the pgbench and refresh logs; index sizes;
                                  the rejected rewrites; which queries each index serves
  docs/05_scalability_report.md   section 2, the large dataset: the runs and averages of
                                  large/ and large/seed_same_machine/; the results table,
                                  targets and growth; the growth groups and the rows,
                                  workers and plan facts they quote; the quoted plans; the
                                  JIT times; storage and B-tree depth (large/sizes.txt);
                                  the R22 bookmark (large/r22_bookmark.txt); and that
                                  large/workload_large.sql is sql/06 with only that changed
  README.md                       our headline numbers, and the Phase 5 line

    python3 benchmarks/check_reports.py

Exit status 0 when every number matches.
"""
import csv
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
RESULTS = ROOT / 'benchmarks' / 'results'
IDS = ['R%02d' % i for i in range(1, 26)] + ['W%02d' % i for i in range(1, 6)]
GROUPS = {   # the query groups of the brief's Phase 5 targets, as the README names them
    'real-time screen': ['R02', 'R03', 'R04', 'R05', 'R06', 'R07', 'R23', 'W01', 'W02', 'W03'],
    'interactive query': ['R01', 'R11', 'R13', 'R18', 'R21', 'R22', 'W05'],
    'report': ['R08', 'R09', 'R10', 'R12', 'R14', 'R15', 'R16', 'R17', 'R19', 'R20', 'R24', 'R25'],
}


class Checker:
    def __init__(self):
        self.checked, self.wrong = 0, []

    def equal(self, where, stated, actual):
        self.checked += 1
        if stated != actual:
            self.wrong.append('%s: the report says %s, the files give %s' % (where, stated, actual))

    def true(self, where, condition, problem):
        self.checked += 1
        if not condition:
            self.wrong.append('%s: %s' % (where, problem))

    def section(self, title):
        print('  %-58s' % title, end='')
        self._mark = (self.checked, len(self.wrong))

    def done(self):
        n, w = self.checked - self._mark[0], len(self.wrong) - self._mark[1]
        print('%5d numbers   %s' % (n, 'ok' if not w else '%d WRONG' % w))


def num(text):
    """'**6,747.052**' -> '6747.052' (kept as text, so the printed precision is compared too)."""
    return text.replace('*', '').replace(',', '').replace('ms', '').strip()


def f3(x):
    return '%.3f' % x


def runs(phase, qid):
    """The Execution Time of every run in a raw plan file, as printed."""
    text = (RESULTS / phase / ('%s.txt' % qid)).read_text()
    return re.findall(r'Execution Time: ([\d.]+) ms', text)


def summary(phase):
    with open(RESULTS / phase / 'summary.csv', newline='') as f:
        return {r['query_id']: r for r in csv.DictReader(f)}


def section(text, heading):
    """The text of one '## ' section, from its heading to the next one."""
    start = text.index('\n## ' + heading)
    end = text.find('\n## ', start + 1)
    return text[start:end if end > 0 else len(text)]


def table_rows(text, first_cell):
    """Rows of the markdown tables whose first cell matches first_cell, split into cells."""
    out = []
    for line in text.splitlines():
        if line.startswith('|'):
            cells = [c.strip() for c in line.strip().strip('|').split('|')]
            m = re.match(first_cell, cells[0])
            if m:
                out.append((m, cells))
    return out


def improvement(before, after):
    return '%.1f%%' % ((float(before) - float(after)) / float(before) * 100)


def speedup(before, after, stated):
    """Stated as '7.3x' below ten and as a whole number ('105x', '1,334x') above."""
    x = float(before) / float(after)
    return ('%.1fx' % x) if '.' in stated else ('{:,}x'.format(int(x + 0.5)))


def check_baseline(c, base, base_runs):
    text = (ROOT / 'docs' / '03_baseline_timings.md').read_text()
    c.section('docs/03: runs, averages and total (section 2)')
    sec2 = section(text, '2. Timing table')
    rows = table_rows(sec2, r'(R\d\d|W\d\d): ')
    c.equal('docs/03 timing table', 'rows %d' % len(rows), 'rows %d' % len(IDS))
    for m, cells in rows:
        qid = m.group(1)
        stated = [num(x) for x in cells[2:6]]
        for i in range(3):
            c.equal('docs/03 %s run %d' % (qid, i + 1), stated[i], base_runs[qid][i])
        c.equal('docs/03 %s average' % qid, stated[3], base[qid]['avg_ms'])
        c.equal('summary.csv %s average of its runs' % qid, base[qid]['avg_ms'],
                f3(sum(map(float, base_runs[qid])) / 3))
    total = [num(x) for x in table_rows(sec2, r'\*\*Total')[0][1][2:6]]
    for i in range(3):
        c.equal('docs/03 total of run %d' % (i + 1), total[i],
                f3(sum(float(base_runs[q][i]) for q in IDS)))
    c.equal('docs/03 total of the averages', total[3], f3(sum(float(base[q]['avg_ms']) for q in IDS)))
    m = re.search(r'it alone is \*\*([\d.]+)%\*\* of the total\. The other 29 queries add up to ([\d,]+) ms', text)
    all_avg = sum(float(base[q]['avg_ms']) for q in IDS)
    c.equal('docs/03 share of R19', m.group(1), '%.1f' % (float(base['R19']['avg_ms']) / all_avg * 100))
    c.equal('docs/03 the other 29', m.group(2), '%d' % round(all_avg - float(base['R19']['avg_ms'])))
    c.done()

    c.section('docs/03: averages and scan types (section 3)')
    for m, cells in table_rows(section(text, '3. Scan type'), r'^(R\d\d|W\d\d)$'):
        qid = m.group(1)
        c.equal('docs/03 section 3 %s average' % qid, num(cells[2]), base[qid]['avg_ms'])
        # every table or index named in the scan-type cell must appear in the plan's scan nodes
        nodes = base[qid]['scan_nodes']
        for name in re.findall(r'`([a-z_0-9]+)`', cells[1]):
            c.true('docs/03 section 3 %s' % qid, name in nodes,
                   'names %s, which no scan in the last run\'s plan reads' % name)
    c.done()


def check_optimization(c, base, opt):
    text = (ROOT / 'docs' / '04_optimization_report.md').read_text()
    c.section('docs/04: before, after, improvement, speed-up (section 2)')
    sec2 = section(text, '2. The optimization table')
    rows = table_rows(sec2, r'^(R\d\d|W\d\d)$')
    c.equal('docs/04 optimization table', 'rows %d' % len(rows), 'rows %d' % len(IDS))
    for m, cells in rows:
        qid = m.group(1)
        before, after, impr = num(cells[1]), num(cells[4]), cells[5]
        c.equal('docs/04 %s before' % qid, before, base[qid]['avg_ms'])
        c.equal('docs/04 %s after' % qid, after, opt[qid]['avg_ms'])
        stated = re.match(r'\**(-?[\d.]+%)\**(?: \(([\d,.]+x)\))?', impr.replace('*', ''))
        c.equal('docs/04 %s improvement' % qid, stated.group(1), improvement(before, after))
        if stated.group(2):
            c.equal('docs/04 %s speed-up' % qid, stated.group(2), speedup(before, after, stated.group(2)))
    tb, ta = (f3(sum(float(s[q]['avg_ms']) for q in IDS)) for s in (base, opt))
    m, cells = table_rows(sec2, r'\*\*Total\*\*')[0]
    c.equal('docs/04 total before', num(cells[1]), tb)
    c.equal('docs/04 total after', num(cells[4]), ta)
    stated = re.match(r'(-?[\d.]+%) \(([\d.]+x)\)', cells[5].replace('*', ''))
    c.equal('docs/04 total improvement', stated.group(1), improvement(tb, ta))
    c.equal('docs/04 total speed-up', stated.group(2), speedup(tb, ta, stated.group(2)))
    c.done()

    c.section('docs/04: headline table')
    m = re.search(r'\| Total of the 30 average times \| \*\*([\d,.]+) ms\*\* \| \*\*([\d,.]+) ms\*\* '
                  r'\(([\d.]+%) less, (\d+)x faster\) \|', text)
    c.equal('docs/04 headline total before', num(m.group(1)), tb)
    c.equal('docs/04 headline total after', num(m.group(2)), ta)
    c.equal('docs/04 headline improvement', m.group(3), improvement(tb, ta))
    c.equal('docs/04 headline speed-up', m.group(4) + 'x', speedup(tb, ta, m.group(4)))
    m = re.search(r'\| Total without R19 [^|]*\| ([\d,.]+) ms \| ([\d,.]+) ms \(([\d.]+%) less\) \|', text)
    nb, na = (f3(sum(float(s[q]['avg_ms']) for q in IDS if q != 'R19')) for s in (base, opt))
    c.equal('docs/04 total without R19 before', num(m.group(1)), nb)
    c.equal('docs/04 total without R19 after', num(m.group(2)), na)
    c.equal('docs/04 total without R19 improvement', m.group(3), improvement(nb, na))
    m = re.search(r'\| Slowest query \| (\w+), ([\d,.]+) ms \| (\w+), ([\d,.]+) ms \|', text)
    for (qid, value), s, label in (((m.group(1), m.group(2)), base, 'before'), ((m.group(3), m.group(4)), opt, 'after')):
        slowest = max(IDS, key=lambda q: float(s[q]['avg_ms']))
        c.equal('docs/04 slowest %s' % label, '%s %s' % (qid, num(value)), '%s %s' % (slowest, s[slowest]['avg_ms']))
    c.done()

def run_text(phase, qid, n):
    """The plan of run n in a raw plan file."""
    text = (RESULTS / phase / ('%s.txt' % qid)).read_text()
    m = re.search(r'=== %s run %d ===\n(.*?)(?=\n=== |\Z)' % (qid, n), text, re.S)
    return m.group(1)


def avg(values, digits=3):
    return '%.*f' % (digits, sum(values) / len(values))


def check_excerpts(c, text, base, opt, idx):
    """Section 5 quotes run 3 of each plan: every timing, row count, cost and
    counter in a quoted block must be in that run of the file it names."""
    sec = section(text, '5. Before/after')
    c.section('docs/04: plan excerpts (section 5)')
    facts = re.compile(r'actual time=[\d.]+\.\.[\d.]+ rows=\d+|cost=[\d.]+\.\.[\d.]+ rows=\d+|'
                       r'Execution Time: [\d.]+ ms|Rows Removed by Filter: \d+|Heap Fetches: \d+|'
                       r'Disk: \d+kB|Timing: Generation [^\n]*')
    for sub in sec.split('\n### ')[1:]:
        qid = sub[:3]
        m = re.match(r'\w+ - [^(]*\(([\d,.]+) → ([\d,.]+) ms\)', sub)
        c.equal('docs/04 section 5 %s heading before' % qid, num(m.group(1)), base[qid]['avg_ms'])
        c.equal('docs/04 section 5 %s heading after' % qid, num(m.group(2)), opt[qid]['avg_ms'])
        pos = 0
        for block in re.finditer(r'```\n(.*?)```', sub, re.S):
            lead = sub[pos:block.start()]
            pos = block.end()
            phase = 'baseline' if 'baseline/' in lead or ('Before' in lead and 'After' not in lead) else 'optimized'
            plan = run_text(phase, qid, 3)
            for fact in facts.findall(block.group(1)):
                c.true('docs/04 section 5 %s %s' % (qid, phase), fact in plan,
                       'quotes "%s", which is not in run 3 of %s/%s.txt' % (fact, phase, qid))
        # one-line "Before:" summaries: a filter count and a time in brackets
        for line in re.findall(r'^Before: (.*)$', sub, re.M):
            plan = run_text('baseline', qid, 3)
            for fact in re.findall(r'Rows Removed by Filter: \d+', line):
                c.true('docs/04 section 5 %s baseline' % qid, fact in plan, 'quotes "%s", not in run 3' % fact)
            for t in re.findall(r'\(([\d.]+) ms\)', line):
                c.true('docs/04 section 5 %s baseline' % qid, 'Execution Time: %s ms' % t in plan,
                       'quotes %s ms, not the time of run 3' % t)
    m = re.search(r'the original OFFSET query still took ([\d.]+) ms \(indexes-only run\)', sec)
    c.equal('docs/04 section 5 R22 indexes-only', m.group(1), idx['R22']['avg_ms'])
    m = re.search(r'read all (\d+) of doctor 16\'s appointments and threw away (\d+) \(([\d.]+) ms\)', sec)
    c.equal('docs/04 section 5 R05 indexes-only', m.group(3), idx['R05']['avg_ms'])
    plan = run_text('indexes_only', 'R05', 3)
    c.true('docs/04 section 5 R05 indexes-only', 'rows=%d ' % (int(m.group(1)) - int(m.group(2))) in plan
           and 'Rows Removed by Filter: %s' % m.group(2) in plan, 'the 151 read / 148 discarded are not in the plan')
    m = re.search(r'estimated cost fell from ([\d.]+) million to ([\d.]+) thousand', sec)
    cost = lambda phase: float(re.search(r'cost=[\d.]+\.\.([\d.]+)', run_text(phase, 'R19', 3)).group(1))
    c.equal('docs/04 section 5 R19 cost before', m.group(1), '%.1f' % (cost('baseline') / 1e6))
    c.equal('docs/04 section 5 R19 cost after', m.group(2), '%.1f' % (cost('optimized') / 1e3))
    c.done()


def check_levers(c, text, base, idx, opt):
    """Section 6: before, original SQL on the indexed database, optimized SQL."""
    c.section('docs/04: indexes alone vs rewrites (section 6)')
    for m, cells in table_rows(section(text, '6. Which lever'), r'^((?:[RW]\d\d(?:, )?)+)$'):
        ids = m.group(1).split(', ')
        cols = [[num(v.replace('(wrong)', '').replace('(right)', '')) for v in cell.split(', ')] for cell in cells[1:4]]
        for qid, b, i, o in zip(ids, *cols):
            digits = len(b.split('.')[1]) if '.' in b else 0     # the before column is sometimes rounded
            c.equal('docs/04 section 6 %s before' % qid, b, '%.*f' % (digits, float(base[qid]['avg_ms'])))
            c.equal('docs/04 section 6 %s indexes only' % qid, i, idx[qid]['avg_ms'])
            c.equal('docs/04 section 6 %s optimized' % qid, o, opt[qid]['avg_ms'])
    c.done()


def check_writes(c, text, base, opt):
    sec = section(text, '7. Write overhead')
    wo = RESULTS / 'write_overhead'
    c.section('docs/04: write overhead (section 7)')
    for m, cells in table_rows(sec, r'^(W\d\d) '):
        c.equal('docs/04 section 7.1 %s before' % m.group(1), num(cells[1]), base[m.group(1)]['avg_ms'])
        c.equal('docs/04 section 7.1 %s after' % m.group(1), num(cells[2]), opt[m.group(1)]['avg_ms'])
    # 7.2 W01: the INSERT latency in pgbench, first vs second statement in a connection, the outlier
    insert = lambda f: re.search(r'^\s*([\d.]+)\s+\d+\s+INSERT', (wo / f).read_text(), re.M).group(1)
    m = re.search(r'averages \*\*([\d.]+) ms without the new indexes and ([\d.]+) ms with them\*\*', sec)
    c.equal('docs/04 section 7.2 pgbench INSERT without', m.group(1), insert('W01_practo_base.txt'))
    c.equal('docs/04 section 7.2 pgbench INSERT with', m.group(2), insert('W01_practo.txt'))
    trials = re.findall(r'^(\w+)\s+trial \d+\s+1st INSERT\s+([\d.]+) ms\s+2nd INSERT\s+([\d.]+) ms',
                        (wo / 'W01_first_vs_second_in_connection.txt').read_text(), re.M)
    rng = lambda db, k: '%.2f-%.2f' % (min(float(t[k]) for t in trials if t[0] == db),
                                       max(float(t[k]) for t in trials if t[0] == db))
    m = re.search(r'the 1st insert took ([\d.-]+) ms without and ([\d.-]+) ms with the new indexes; '
                  r'the 2nd took ([\d.-]+) ms and ([\d.-]+) ms', sec)
    for stated, (db, k) in zip(m.groups(), [('practo_base', 1), ('practo', 1), ('practo_base', 2), ('practo', 2)]):
        c.equal('docs/04 section 7.2 first/second insert %s' % db, stated, rng(db, k))
    m = re.search(r'in run 5 the foreign-key check on `patients` alone took ([\d.]+) ms', sec)
    c.true('docs/04 section 7.2 outlier', re.search(r'fk_appt_patient[^\n]*time=%s ' % re.escape(m.group(1)),
                                                     run_text('optimized', 'W01', 5)) is not None,
           'the %s ms trigger time is not in run 5' % m.group(1))
    m = re.search(r'the median is ([\d.]+) ms', sec)
    c.equal('docs/04 section 7.2 W01 median', m.group(1), opt['W01']['median_ms'])
    # 7.3 W04: finding the rows (the scan under the Update node) and writing them (the rest of the node)
    for label, phase, n in (('Before', 'baseline', 3), ('After', 'optimized', 5)):
        find, write = [], []
        for i in range(1, n + 1):
            plan = run_text(phase, 'W04', i)
            update = float(re.search(r'^Update on appointments .*actual time=[\d.]+\.\.([\d.]+)', plan, re.M).group(1))
            scan = float(re.search(r'^\s+->\s+.*actual time=[\d.]+\.\.([\d.]+)', plan, re.M).group(1))
            find.append(scan)
            write.append(update - scan)
        m = re.search(r'\| %s \(avg of %d\) \| ([\d.]+) ms [^|]*\| ([\d.]+) ms \| ([\d.]+) ms \|' % (label, n), sec)
        c.equal('docs/04 section 7.3 W04 %s finding' % label, m.group(1), avg(find))
        c.equal('docs/04 section 7.3 W04 %s writing' % label, m.group(2), avg(write))
        c.equal('docs/04 section 7.3 W04 %s total' % label, m.group(3), (base if phase == 'baseline' else opt)['W04']['avg_ms'])
        if label == 'Before':
            write_before = float(m.group(2))
        else:
            per_row = re.search(r'Writing became \*\*(\d+)% more expensive per row\*\*', sec).group(1)
            c.equal('docs/04 section 7.3 W04 per-row cost', per_row, '%d' % round((float(m.group(2)) / write_before - 1) * 100))
    latency = lambda f: re.search(r'latency average = ([\d.]+) ms', (wo / f).read_text()).group(1)
    m = re.search(r'W04 went from ([\d.]+) to ([\d.]+) ms per execution', sec)
    c.equal('docs/04 section 7.3 pgbench W04', m.groups(), (latency('W04_practo_base.txt'), latency('W04_practo.txt')))
    m = re.search(r'`pgbench` W02 ([\d.]+) → ([\d.]+) ms and W05 ([\d.]+) → ([\d.]+) ms', sec)
    c.equal('docs/04 section 7.3 pgbench W02, W05', m.groups(),
            tuple(latency(f) for f in ('W02_practo_base.txt', 'W02_practo.txt', 'W05_practo_base.txt', 'W05_practo.txt')))
    # 7.4 refresh of the summary tables: the log alternates the two views
    times = [float(t) for t in re.findall(r'Time: ([\d.]+) ms', (wo / 'mv_refresh.txt').read_text())]
    for name, ts in (('doctor_rating_summary', times[0::2]), ('monthly_medicine_by_specialization', times[1::2])):
        m = re.search(r'`%s` ([\d.]+)-([\d.]+) ms \(avg ([\d.]+)\)' % name, sec)
        c.equal('docs/04 section 7.4 %s' % name, m.groups(), ('%.1f' % min(ts), '%.1f' % max(ts), avg(ts, 1)))
    c.done()


def check_storage(c, text, opt):
    """Section 8 against index_sizes.txt (pg_relation_size, in bytes and as pg_size_pretty prints them),
    and its Serves column against the optimized plans: the queries named must be exactly those whose
    plan reads the object."""
    sec = section(text, '8. Index storage')
    raw = (RESULTS / 'optimized' / 'index_sizes.txt').read_text()
    rows = {r[0]: r for r in (l.split('|') for l in raw.splitlines()) if len(r) == 6 and r[3].strip().isdigit()}
    rows = {k.strip(): [x.strip() for x in v] for k, v in rows.items()}
    after = dict(l.split(' | ') for l in raw.split('AFTER all benchmark passes')[1].strip().splitlines()[1:] if ' | ' in l)
    mib = lambda name: int(rows[name][3]) / 1048576
    c.section('docs/04: index storage (section 8)')
    for m, cells in table_rows(sec, r'^`(\w+)`$'):
        name = m.group(1)
        users = sorted((q for q in IDS if re.search(r'\b%s\b' % name, opt[q]['scan_nodes'])), key=IDS.index)
        c.equal('docs/04 section 8 %s serves' % name, ', '.join(re.findall(r'[RW]\d\d', cells[5])), ', '.join(users))
        sizes = [x.strip().replace(',', '') for x in cells[3].split('+')]
        if rows[name][1] == 'materialized view':
            unique = [k for k, v in rows.items() if v[2] == name][0]
            c.equal('docs/04 section 8 %s' % name, sizes, [rows[name][4], rows[unique][4]])
        else:
            c.equal('docs/04 section 8 %s size' % name, sizes[0], rows[name][4])
            c.equal('docs/04 section 8 %s share of its table' % name, cells[4], rows[name][5] + '%')
            t = re.match(r'(\w+)(?: \(([\d.]+) MB\))?', cells[2])
            if t.group(2):
                digits = len(t.group(2).split('.')[1]) if '.' in t.group(2) else 0
                c.equal('docs/04 section 8 size of %s' % t.group(1), t.group(2), '%.*f' % (digits, mib(t.group(1))))
    m = re.search(r'\*\*Database size: (\d+) MB → (\d+) MB\*\* \(\+(\d+) MB, \+(\d+)%\)', sec)
    db = re.search(r'^\s*(\d+) MB\s*\|\s*(\d+) MB', raw, re.M)
    c.equal('docs/04 section 8 database size', (m.group(1), m.group(2)), (db.group(2), db.group(1)))
    c.equal('docs/04 section 8 growth', (m.group(3), m.group(4)),
            ('%d' % (int(db.group(1)) - int(db.group(2))), '%d' % round((int(db.group(1)) / int(db.group(2)) - 1) * 100)))
    m = re.search(r'covering indexes on `appointments` \(([\d.]+) MB together, (\d+)% of the table', sec)
    cover = ['ix_appt_doctor_slot', 'ix_appt_patient', 'ix_appt_slot_cover']
    c.equal('docs/04 section 8 covering indexes', m.groups(),
            ('%.1f' % sum(mib(n) for n in cover), '%d' % round(sum(mib(n) for n in cover) / mib('appointments') * 100)))
    m = re.search(r'`ix_appt_doctor_slot` had grown from ([^ ]+(?: kB)?) to ([^ ]+ [kM]B) and `ix_appt_patient` '
                  r'from ([^ ]+(?: kB)?) to ([^ ]+ [kM]B), while `ix_appt_slot_cover` grew only from ([^ ]+(?: kB)?) '
                  r'to ([^ ]+ [kM]B)', sec)
    for k, name in enumerate(cover):
        c.equal('docs/04 section 8 bloat of %s' % name,
                (m.group(2 * k + 1).replace(',', ''), m.group(2 * k + 2).replace(',', '')),
                (rows[name][4], after[name].strip()))
    c.done()


def check_rejected(c, text, base, opt):
    sec = section(text, '9. Queries we could not')
    c.section('docs/04: queries not sped up, rejected rewrites (section 9)')
    for m, cells in table_rows(sec, r'^\*\*(R\d\d)\*\*'):
        qid = m.group(1)
        b, a = re.match(r'([\d.]+) → ([\d.]+) ms', cells[1]).groups()
        c.equal('docs/04 section 9 %s before' % qid, b, base[qid]['avg_ms'])
        c.equal('docs/04 section 9 %s after' % qid, a, opt[qid]['avg_ms'])
    for name, pattern in (('R24_groups_first', r'Find duplicate groups first, then join back: \*\*([\d.]+) ms\*\*'),
                          ('R24_lag_window', r'with `lag\(\)` over `ix_appt_doctor_slot`: \*\*([\d.]+) ms\*\*'),
                          ('R25_two_level_distinct', r'instead of `count\(DISTINCT\)`: \*\*([\d.]+) ms\*\*'),
                          ('R01_exists', r'`EXISTS` instead of `JOIN` \+ `DISTINCT`: \*\*([\d.]+) ms\*\*')):
        t = [float(x) for x in re.findall(r'Execution Time: ([\d.]+) ms', (RESULTS / 'rejected' / (name + '.txt')).read_text())]
        c.equal('docs/04 section 9 rejected %s' % name, re.search(pattern, sec).group(1), avg(t))
    m = re.search(r'\(R12, R17 and R25: (\d+) heap fetches per run', sec)
    for qid in ('R12', 'R17', 'R25'):
        c.true('docs/04 section 9 %s heap fetches' % qid,
               all('Heap Fetches: %s' % m.group(1) in run_text('optimized', qid, i) for i in range(1, 6)),
               'not every run shows Heap Fetches: %s' % m.group(1))
    c.done()


def check_readme(c, base, opt):
    text = (ROOT / 'README.md').read_text()
    c.section('README: our results')
    tb, ta = (f3(sum(float(s[q]['avg_ms']) for q in IDS)) for s in (base, opt))
    m = re.search(r'\| Total of the 30 average times \| ([\d,.]+) ms \| \*\*([\d,.]+) ms\*\* '
                  r'\(([\d.]+%) less, (\d+)x faster\) \|', text)
    c.equal('README total before', num(m.group(1)), tb)
    c.equal('README total after', num(m.group(2)), ta)
    c.equal('README improvement', m.group(3), improvement(tb, ta))
    c.equal('README speed-up', m.group(4) + 'x', speedup(tb, ta, m.group(4)))
    for label, ids in GROUPS.items():
        m = re.search(r'\| Slowest %s \([^)]*\) \| (\w+), ([\d,.]+) ms \| (\w+), ([\d,.]+) ms \|' % label, text)
        for (qid, value), s, when in (((m.group(1), m.group(2)), base, 'before'), ((m.group(3), m.group(4)), opt, 'after')):
            slowest = max(ids, key=lambda q: float(s[q]['avg_ms']))
            c.equal('README slowest %s %s' % (label, when), '%s %s' % (qid, num(value)),
                    '%s %s' % (slowest, s[slowest]['avg_ms']))
    m = re.search(r'\| Nightly batch \(W04\) \| ([\d.]+) ms \| ([\d.]+) ms \|', text)
    c.equal('README W04 before', m.group(1), base['W04']['avg_ms'])
    c.equal('README W04 after', m.group(2), opt['W04']['avg_ms'])
    c.done()


LARGE, SEED_HERE = 'large', 'large/seed_same_machine'   # Phase 5: the large run, and the seed run on its machine
TARGET = dict([(q, 5) for q in GROUPS['real-time screen']] + [(q, 250) for q in GROUPS['interactive query']]
              + [(q, 5000) for q in GROUPS['report']] + [('W04', 1000)])
SCAN = re.compile(r'(?:Parallel )?(?:Seq Scan|Index Scan|Index Only Scan|Bitmap Heap Scan)(?: Backward)?'
                  r'(?: using \w+)? on (\w+)[^\n]*?actual time=[\d.]+\.\.[\d.]+ rows=(\d+) loops=(\d+)')
PLAN_FACT = re.compile(r'^(Rows Removed by Filter: \d+|Batches: \d+|Memory Usage: \d+kB|Disk: \d+kB|'
                       r'Total [\d.]+ ms|loops=\d+)$')


def subsection(text, heading):
    """The text of one '### ' subsection, up to the next heading."""
    start = text.index('\n### ' + heading)
    m = re.search(r'\n#{2,3} ', text[start + 1:])
    return text[start:start + 1 + m.start()] if m else text[start:]


def scan_rows(plan, table):
    """Rows returned by every scan of a table in a plan (rows x loops, summed)."""
    return sum(int(r) * int(l) for t, r, l in SCAN.findall(plan) if t == table)


def workers(plan):
    return max([int(x) for x in re.findall(r'Workers Launched: (\d+)', plan)] or [0])


def top_rows(plan):
    return int(re.search(r'actual time=[\d.]+\.\.[\d.]+ rows=(\d+)', plan).group(1))


def in_plan(fact, plan):
    return re.search(re.escape(fact) + r'(?![\d.])', plan) is not None


def read_sizes():
    """large/sizes.txt, for 'LARGE' and 'SEED': tables, totals, Phase 4 objects and B-tree levels."""
    out = {}
    for part in (RESULTS / LARGE / 'sizes.txt').read_text().split('\n########## ')[1:]:
        d, header = {'tables': {}, 'objects': {}, 'levels': {}}, None
        for line in part.splitlines():
            cells = [x.strip() for x in line.split('|')]
            if len(cells) < 3:
                continue
            if cells[0] in ('table', 'tables_bytes', 'object', 'phase4_objects_total', 'on_table'):
                header = cells[0]
            elif header == 'table':
                d['tables'][cells[0]] = dict(zip(('kind', 'rows', 'bytes', 'size', 'index_bytes', 'index_size'),
                                                 [cells[1], int(cells[2]), int(cells[3]), cells[4], int(cells[5]), cells[6]]))
            elif header == 'tables_bytes':
                d['totals'] = dict(zip(('tables_bytes', 'tables', 'indexes_bytes', 'indexes', 'summary_bytes', 'summary',
                                        'db_bytes', 'db'), cells))
            elif header == 'object':
                d['objects'][cells[0]] = dict(kind=cells[1], on=cells[2], bytes=int(cells[3]), size=cells[4])
            elif header == 'phase4_objects_total':
                d['p4'] = dict(zip(('total', 'indexes', 'summary'), cells))
            elif header == 'on_table':
                d['levels'][cells[1]] = int(cells[2])
        out[part.split()[0]] = d
    return out


def check_scalability(c, opt):
    """docs/05 section 2 against benchmarks/results/large/."""
    text = (ROOT / 'docs' / '05_scalability_report.md').read_text()
    sec = section(text, '2. Measured on the large dataset')
    big, here = summary(LARGE), summary(SEED_HERE)
    growth = {q: float(big[q]['avg_ms']) / float(here[q]['avg_ms']) for q in IDS}
    total = lambda s: sum(float(s[q]['avg_ms']) for q in IDS)
    plan_large = lambda q: run_text(LARGE, q, 3)
    plan_seed = lambda q: run_text(SEED_HERE, q, 5)
    size = read_sizes()
    L, S = size['LARGE'], size['SEED']
    times = lambda b: '%.1fx' % b
    mb = lambda s: s.replace(',', '')

    c.section('docs/05: the runs behind section 2')
    for phase, n in ((LARGE, 3), (SEED_HERE, 5)):
        s = summary(phase)
        for q in IDS:
            r = runs(phase, q)
            c.equal('%s/%s number of runs' % (phase, q), len(r), n)
            c.equal('%s/%s average' % (phase, q), s[q]['avg_ms'], avg([float(x) for x in r]))
    # the workload: sql/06 with the R22 bookmark taken from the large data, nothing else
    split = lambda t: dict(re.findall(r'^-- @([RW]\d\d)\n(.*?)(?=^-- @)', t, re.S | re.M))
    body = lambda sql: [l for l in sql.splitlines() if not l.startswith('--')]
    ours, given = (split(p.read_text()) for p in (RESULTS / LARGE / 'workload_large.sql', ROOT / 'sql' / '06_optimized_queries.sql'))
    c.equal('workload_large.sql queries', sorted(ours), IDS)
    for q in IDS:
        diff = [(a, b) for a, b in zip(body(ours[q]), body(given[q])) if a != b]
        c.true('workload_large.sql %s' % q, len(body(ours[q])) == len(body(given[q])) and len(diff) == (q == 'R22'),
               'differs from sql/06_optimized_queries.sql' if q != 'R22' else 'should differ in the bookmark line only')
    bm = (RESULTS / LARGE / 'r22_bookmark.txt').read_text()
    mark = re.search(r'^ (\S+ \S+) \|\s+(\d+)\s*$', bm, re.M)
    c.true('workload_large.sql R22 bookmark', "(TIMESTAMPTZ '%s', %s)" % mark.groups() in ours['R22'],
           'is not the row in r22_bookmark.txt')
    c.done()

    c.section('docs/05: results table and headline (sections 1, 2, 2.1, 2.2)')
    m = re.search(r'This machine is (\d+)% faster: ([\d.]+) ms for the 30 queries, against ([\d.]+) ms in Phase 4', sec)
    c.equal('docs/05 2.1 same-machine total', m.group(2), f3(total(here)))
    c.equal('docs/05 2.1 Phase 4 total', m.group(3), f3(total(opt)))
    c.equal('docs/05 2.1 faster by', m.group(1), '%d' % round((1 - total(here) / total(opt)) * 100))
    names = {'appointments': 'appointments', 'prescription items': 'prescription_items', 'prescriptions': 'prescriptions',
             'patients': 'patients', 'doctor schedules': 'doctor_schedules', 'reviews': 'doctor_reviews',
             'doctors': 'doctors', 'clinics': 'clinics'}
    data = re.search(r'\*\*Data\.\*\*.*', sec).group(0)
    for n, what in re.findall(r'([\d,]+) (prescription items|doctor schedules|appointments|prescriptions|patients|'
                              r'reviews|doctors|clinics)\b', data):
        c.equal('docs/05 2.1 rows of %s' % what, mb(n), str(L['tables'][names[what]]['rows']))
    groups = {'real-time': GROUPS['real-time screen'], 'interactive': GROUPS['interactive query'],
              'report': GROUPS['report'], 'batch': ['W04']}
    for label, qid, value, target in re.findall(r'(real-time|interactive|report|batch) ([RW]\d\d), ([\d,.]+) ms '
                                                r'\(target ([\d,]+) ms\)', sec):
        slowest = max(groups[label], key=lambda q: float(big[q]['avg_ms']))
        c.equal('docs/05 2 slowest %s' % label, (qid, num(value), mb(target)),
                (slowest, big[slowest]['avg_ms'], str(TARGET[slowest])))
    rows = table_rows(subsection(sec, '2.2'), r'^([RW]\d\d)$')
    c.equal('docs/05 results table', 'rows %d' % len(rows), 'rows %d' % len(IDS))
    for m, cells in rows:
        q = m.group(1)
        c.equal('docs/05 %s seed, Phase 4' % q, num(cells[2]), opt[q]['avg_ms'])
        c.equal('docs/05 %s seed, same machine' % q, num(cells[3]), here[q]['avg_ms'])
        c.equal('docs/05 %s large' % q, num(cells[4]), big[q]['avg_ms'])
        c.equal('docs/05 %s growth' % q, cells[5], times(growth[q]))
        c.equal('docs/05 %s target' % q, mb(re.search(r'< ([\d,]+) ms', cells[1]).group(1)), str(TARGET[q]))
        c.equal('docs/05 %s meets target' % q, cells[6], 'Yes' if float(big[q]['avg_ms']) < TARGET[q] else 'No')
    cells = table_rows(sec, r'^\*\*Total of the 30\*\*$')[0][1]
    c.equal('docs/05 total', [num(x) for x in cells[2:6]],
            [f3(total(opt)), f3(total(here)), f3(total(big)), times(total(big) / total(here))])
    m = re.search(r'the total of the 30 average times grew ([\d.]+x) on the same machine \(([\d.,]+) ms → ([\d.,]+) ms\); '
                  r'the slowest query is ([RW]\d\d), at ([\d.,]+) ms of its ([\d,]+) ms target', text)
    worst = max(IDS, key=lambda q: float(big[q]['avg_ms']))
    c.equal('docs/05 1 headline', (m.group(1), num(m.group(2)), num(m.group(3)), m.group(4), num(m.group(5)), mb(m.group(6))),
            (times(total(big) / total(here)), f3(total(here)), f3(total(big)), worst, big[worst]['avg_ms'], str(TARGET[worst])))
    m = re.search(r'every real-time screen answers in under 1 ms \(the slowest, ([RW]\d\d), in ([\d.]+) ms\)', text)
    slowest = max(GROUPS['real-time screen'], key=lambda q: float(big[q]['avg_ms']))
    c.equal('docs/05 6 slowest real-time', m.groups(), (slowest, big[slowest]['avg_ms']))
    c.true('docs/05 6 real-time under 1 ms', float(big[slowest]['avg_ms']) < 1, 'it is not under 1 ms')
    m = re.search(r'all 30 optimized queries meet their targets with no change to any index or query; the slowest, '
                  r'([RW]\d\d), takes ([\d,.]+) ms of its ([\d,]+) ms', (ROOT / 'README.md').read_text())
    c.equal('README Phase 5 slowest', (m.group(1), num(m.group(2)), mb(m.group(3))), (worst, big[worst]['avg_ms'], str(TARGET[worst])))
    c.true('Phase 5 every target met', all(float(big[q]['avg_ms']) < TARGET[q] for q in IDS), 'a query misses its target')
    # parameters picked on the seed data: rows found on each data set
    for q, large_n, seed_n in re.findall(r'(R\d\d) (?:returns )?(\d+)(?: rows)? instead of (\d+)', sec):
        c.equal('docs/05 2.2 rows of %s' % q, (large_n, seed_n), (str(top_rows(plan_large(q))), str(top_rows(plan_seed(q)))))
    m = re.search(r'W03 and W05 change (\d+) rows instead of (\d+) and (\d+)', sec)
    c.equal('docs/05 2.2 rows W03 and W05 change',
            (m.group(1), m.group(1), m.group(2), m.group(3)),
            tuple(str(scan_rows(p(q), t)) for p, q, t in ((plan_large, 'W03', 'prescriptions'), (plan_large, 'W05', 'appointments'),
                                                          (plan_seed, 'W03', 'prescriptions'), (plan_seed, 'W05', 'appointments'))))
    c.done()

    c.section('docs/05: growth analysis (section 2.3)')
    sub = subsection(sec, '2.3')
    seen = []
    for chunk in sub.split('\n**')[1:]:
        m = re.match(r'([^,]+(?:, but less than 20x)?), ([\d.]+)x to ([\d.]+)x([^*]*)\.\*\*', chunk)
        if not m:
            continue
        ids = re.findall(r'[RW]\d\d', m.group(4)) or [r[0].group(1) for r in table_rows(chunk, r'^([RW]\d\d)$')]
        seen += ids
        c.equal('docs/05 2.3 range "%s"' % m.group(1), (m.group(2), m.group(3)),
                ('%.1f' % min(growth[q] for q in ids), '%.1f' % max(growth[q] for q in ids)))
    c.equal('docs/05 2.3 every query in one group', sorted(seen), IDS)
    for m, cells in table_rows(sub, r'^([RW]\d\d)$'):
        q = m.group(1)
        c.equal('docs/05 2.3 %s growth' % q, cells[1], times(growth[q]))
        for table, a, b in re.findall(r'`(\w+)`: ([\d,]+) → ([\d,]+)', cells[2]):
            c.equal('docs/05 2.3 %s rows of %s' % (q, table), (mb(a), mb(b)),
                    (str(scan_rows(plan_seed(q), table)), str(scan_rows(plan_large(q), table))))
        w = re.match(r'(\d+) → (\d+)$', cells[3])
        c.equal('docs/05 2.3 %s workers' % q, w.groups(), (str(workers(plan_seed(q))), str(workers(plan_large(q)))))
        pairs = re.findall(r'`([^`]+)` → `([^`]+)`', cells[4])
        for a, b in pairs:
            c.true('docs/05 2.3 %s' % q, in_plan(a, plan_seed(q)), '"%s" is not in run 5 of the seed plan' % a)
            c.true('docs/05 2.3 %s' % q, in_plan(b, plan_large(q)), '"%s" is not in run 3 of the large plan' % b)
        for fact in re.findall(r'`([^`]+)`', re.sub(r'`[^`]+` → `[^`]+`', '', cells[4])):
            if PLAN_FACT.match(fact):
                c.true('docs/05 2.3 %s' % q, in_plan(fact, plan_large(q)), '"%s" is not in run 3 of the large plan' % fact)
    m = re.search(r'\(((?:`\w+`(?:, )?)+)\) have (\d+) levels on both data sets', sub)
    for name in re.findall(r'`(\w+)`', m.group(1)):
        c.equal('docs/05 2.3 levels of %s' % name, (S['levels'][name], L['levels'][name]), (int(m.group(2)),) * 2)
    m = re.search(r'((?:`\w+`(?:, | and ))*`\w+`) went from (\d+) levels to (\d+)', sub)
    for name in re.findall(r'`(\w+)`', m.group(1)):
        c.equal('docs/05 2.3 levels of %s' % name, (S['levels'][name], L['levels'][name]), (int(m.group(2)), int(m.group(3))))
    c.true('docs/05 2.3 at most one level more', all(L['levels'][i] - S['levels'][i] <= 1 for i in S['levels']),
           'an index grew by more than one level')
    m = re.search(r'R15 reads (\d+) rows of `(\w+)`, which has ([\d,]+) rows on both data sets', sub)
    c.equal('docs/05 2.3 R15', (m.group(1), m.group(1), mb(m.group(3)), mb(m.group(3))),
            (str(scan_rows(plan_seed('R15'), m.group(2))), str(scan_rows(plan_large('R15'), m.group(2))),
             str(S['tables'][m.group(2)]['rows']), str(L['tables'][m.group(2)]['rows'])))
    m = re.search(r'\(R22 after (\d+), W02 after (\d+)\)', sub)
    c.equal('docs/05 2.3 R22 and W02 stop after', m.groups(),
            (str(top_rows(plan_large('R22'))),
             re.search(r'Index Only Scan using ix_appt_slot_cover on appointments[^\n]*rows=(\d+) loops=1', plan_large('W02')).group(1)))
    c.done()

    c.section('docs/05: what changed at scale, R22 (sections 2.4, 2.5)')
    sub = subsection(sec, '2.4')
    for folder, q, n, block in re.findall(r'`([\w_]+)/([RW]\d\d)\.txt`, run (\d+):\n```\n(.*?)```', sub, re.S):
        plan = run_text(LARGE if folder == 'large' else 'large/' + folder, q, int(n))
        for line in block.strip().splitlines():
            c.true('docs/05 2.4 %s/%s run %s' % (folder, q, n), line.strip() in plan, 'quotes a line not in the plan: ' + line.strip())
    m = re.search(r'At ([\d,.]+) ms (R\d\d) uses half of its ([\d,]+) ms target, the most of any query', sub)
    share = {q: float(big[q]['avg_ms']) / TARGET[q] for q in IDS}
    c.equal('docs/05 2.4 R24', (num(m.group(1)), mb(m.group(3))), (big[m.group(2)]['avg_ms'], str(TARGET[m.group(2)])))
    c.true('docs/05 2.4 R24 share', max(share, key=share.get) == m.group(2) and 0.45 <= share[m.group(2)] < 0.55,
           'is not the query with the largest share of its target, or not about half')
    jit = re.search(r'part of their Execution Time: (.*?) \(run 3 of each\)', sub).group(1)
    named = re.findall(r'([RW]\d\d) ([\d.]+) ms', jit)
    for q, t in named:
        c.true('docs/05 2.4 JIT %s' % q, in_plan('Total %s ms' % t, plan_large(q)), 'JIT time is not that of run 3')
    with_jit = [q for q in IDS if 'JIT:' in (RESULTS / LARGE / ('%s.txt' % q)).read_text()]
    c.equal('docs/05 2.4 large plans with JIT', sorted(q for q, t in named), with_jit)
    c.true('docs/05 2.4 no JIT on the seed data', not any('JIT:' in (RESULTS / p / ('%s.txt' % q)).read_text()
                                                         for p in ('optimized', SEED_HERE) for q in IDS),
           'an optimized seed plan uses JIT')
    c.true('docs/05 2.4 memory', 'Batches: 8' in plan_large('R17') and 'R17 is split into 8 batches' in sub
           and all('external merge' in plan_large(q) for q in ('R24', 'R25'))
           and not any(re.search(r'Disk: |Batches: (?!1\b)\d', plan_seed(q)) for q in ('R17', 'R24', 'R25')),
           'the batches and sorts on disk are not as stated')
    m = re.search(r'the whole seed database \((\d+) MB\) but a small part of the large one \(([\d,]+) MB\)', sub)
    c.equal('docs/05 2.4 database sizes', (m.group(1) + ' MB', mb(m.group(2)) + ' MB'), (S['totals']['db'], L['totals']['db']))
    first_buffers = lambda plan: re.search(r'Buffers: [^\n]*', plan).group(0)
    for q in re.search(r'(R\d\d), (R\d\d) and (R\d\d) now read pages from outside it', sub).groups():
        c.true('docs/05 2.4 %s reads' % q, 'read=' in first_buffers(plan_large(q)) and 'read=' not in first_buffers(plan_seed(q)),
               'does not read outside shared buffers on the large data only')
    sub = subsection(sec, '2.5')
    before = int(re.search(r'^\s+(\d+)\s*$', bm.split('rows_before_seed_bookmark')[1], re.M).group(1))
    check = re.search(r'^\s+(\d+) \|\s+(\d+) \|\s+(\d+) \|\s+(\d+)\s*$', bm, re.M).groups()
    m = re.search(r'-- \((\S+ \S+), (\d+)\)', sub)
    c.equal('docs/05 2.5 bookmark', m.groups(), mark.groups())
    m = re.search(r'and ([\d,]+) large-data rows come before it: reused, it would show rows ([\d,]+) to ([\d,]+)', sub)
    c.equal('docs/05 2.5 seed bookmark', tuple(mb(x) for x in m.groups()), (str(before), str(before + 1), str(before + 25)))
    c.true('docs/05 2.5 seed bookmark not a row', re.search(r'seed_bookmark_rows\s*\n-+\n\s+0\s*$', bm, re.M) is not None,
           'r22_bookmark.txt does not say 0 rows')
    m = re.search(r'\((\d+) rows differ\), in ([\d.]+) ms: it reads (\d+) index entries', sub)
    c.equal('docs/05 2.5 check', (check[0], check[1], str(int(check[2]) + int(check[3])), m.group(1)), ('25', '25', m.group(1), '0'))
    c.equal('docs/05 2.5 R22', (m.group(2), m.group(3)), (big['R22']['avg_ms'], str(scan_rows(plan_large('R22'), 'appointments'))))
    c.done()

    c.section('docs/05: storage (section 2.6)')
    sub = subsection(sec, '2.6')
    t = lambda d, name: d['tables'][name]
    p4 = lambda d: (sum(o['bytes'] for n, o in d['objects'].items() if n.startswith('ix_')),
                    sum(o['bytes'] for n, o in d['objects'].items() if not n.startswith('ix_')))
    expect = {
        'Database': ((S['totals']['db'], L['totals']['db']), (int(S['totals']['db_bytes']), int(L['totals']['db_bytes']))),
        'The 11 tables': ((S['totals']['tables'], L['totals']['tables']),
                          (int(S['totals']['tables_bytes']), int(L['totals']['tables_bytes']))),
        'Their indexes': ((S['totals']['indexes'], L['totals']['indexes']),
                          (int(S['totals']['indexes_bytes']), int(L['totals']['indexes_bytes']))),
        '`appointments`': ((t(S, 'appointments')['size'], t(L, 'appointments')['size']),
                           (t(S, 'appointments')['bytes'], t(L, 'appointments')['bytes'])),
        'Indexes on `appointments`': ((t(S, 'appointments')['index_size'], t(L, 'appointments')['index_size']),
                                      (t(S, 'appointments')['index_bytes'], t(L, 'appointments')['index_bytes'])),
        'The 7 Phase 4 indexes': ((S['p4']['indexes'], L['p4']['indexes']), (p4(S)[0], p4(L)[0])),
        'The 2 summary tables, with their indexes': ((S['p4']['summary'], L['p4']['summary']), (p4(S)[1], p4(L)[1])),
    }
    rows = table_rows(sub, r'^(Database|The 11 tables|Their indexes|`appointments`|Indexes on `appointments`|'
                           r'The 7 Phase 4 indexes|The 2 summary tables, with their indexes)$')
    c.equal('docs/05 2.6 storage rows', sorted(m.group(1) for m, _ in rows), sorted(expect))
    for m, cells in rows:
        pretty, raw = expect[m.group(1)]
        c.equal('docs/05 2.6 %s' % m.group(1), (mb(cells[1]), mb(cells[2]), cells[3]), pretty + (times(raw[1] / raw[0]),))
    ratio = lambda d: '%.1f' % (t(d, 'appointments')['index_bytes'] / t(d, 'appointments')['bytes'])
    m = re.search(r'the indexes on `appointments` are ([\d.]+)x the size of the table on both data sets', sub)
    c.equal('docs/05 2.6 index to table', (m.group(1),) * 2, (ratio(S), ratio(L)))
    m = re.search(r'The summary tables grew ([\d.]+x) because one of them, the month × specialization × medicine summary, '
                  r'does not grow at all', sub)
    mm = 'monthly_medicine_by_specialization'
    c.equal('docs/05 2.6 summary tables', m.group(1), times(p4(L)[1] / p4(S)[1]))
    c.equal('docs/05 2.6 %s does not grow' % mm, (t(S, mm)['rows'], t(S, mm)['bytes']), (t(L, mm)['rows'], t(L, mm)['bytes']))
    m = re.search(r'The database as a whole grew ([\d.]+x), less than its tables and indexes', sub)
    db, tb, ib = (int(L['totals'][k]) / int(S['totals'][k]) for k in ('db_bytes', 'tables_bytes', 'indexes_bytes'))
    c.equal('docs/05 2.6 database growth', m.group(1), times(db))
    c.true('docs/05 2.6 database grew less', db < tb and db < ib, 'the database did not grow less than its tables and indexes')
    rest = lambda d: int(d['totals']['db_bytes']) - int(d['totals']['tables_bytes']) - int(d['totals']['indexes_bytes']) \
        - int(d['totals']['summary_bytes'])
    m = re.search(r"PostgreSQL's own catalogs, about (\d+) MB on both data sets", sub)
    c.equal('docs/05 2.6 catalogs', (m.group(1),) * 2, tuple('%d' % round(rest(d) / 1048576) for d in (S, L)))
    m = re.search(r'measured ([\d,]+) bytes, which `pg_size_pretty` prints as (\d+ MB)\) and low for the indexes '
                  r'\(about 340 MB; measured (\d+ MB) on `appointments` alone and (\d+ MB) on all tables\)', sub)
    c.equal('docs/05 2.6 estimate', (mb(m.group(1)), m.group(2), m.group(3), m.group(4)),
            (str(t(L, 'appointments')['bytes']), t(L, 'appointments')['size'], t(L, 'appointments')['index_size'], L['totals']['indexes']))
    c.done()


def main():
    base, opt, idx = summary('baseline'), summary('optimized'), summary('indexes_only')
    base_runs = {q: runs('baseline', q) for q in IDS}
    for q in IDS:
        if len(base_runs[q]) != 3:
            sys.exit('baseline/%s.txt has %d runs, not 3' % (q, len(base_runs[q])))
    c = Checker()
    print('Numbers in the reports against benchmarks/results/')
    check_baseline(c, base, base_runs)
    check_optimization(c, base, opt)
    text = (ROOT / 'docs' / '04_optimization_report.md').read_text()
    check_excerpts(c, text, base, opt, idx)
    check_levers(c, text, base, idx, opt)
    check_writes(c, text, base, opt)
    check_storage(c, text, opt)
    check_rejected(c, text, base, opt)
    check_readme(c, base, opt)
    check_scalability(c, opt)
    for w in c.wrong:
        print('  WRONG ' + w)
    print('%d numbers checked, %s' % (c.checked, 'all match.' if not c.wrong else '%d do not match.' % len(c.wrong)))
    sys.exit(1 if c.wrong else 0)


if __name__ == '__main__':
    main()
