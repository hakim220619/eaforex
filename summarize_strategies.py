import json
from collections import defaultdict

with open('benchmark_results_5days.json', 'r', encoding='utf-8') as f:
    data = json.load(f)

groups = defaultdict(lambda: {
    'trades': 0, 'wins': 0, 'losses': 0,
    'net_profit': 0.0, 'best_pair': '', 'best_pnl': -99999.0,
    'breakdowns': []
})

for r in data:
    strat = r['strategy_name'].split(' (')[0]
    g = groups[strat]
    g['trades'] += r['total_trades']
    g['wins'] += r['wins']
    g['losses'] += r['losses']
    g['net_profit'] += r['net_profit']
    g['breakdowns'].append((r['symbol'].upper(), r['tf'].upper(), r['net_profit'], r['total_trades']))
    if r['net_profit'] > g['best_pnl']:
        g['best_pnl'] = r['net_profit']
        g['best_pair'] = f"{r['symbol'].upper()} ({r['tf'].upper()})"

print(f"{'Nama Strategi EA':<24} | {'Total Trades':<12} | {'Win Rate':<8} | {'Total Net Profit':<16} | {'Setup Paling Cuan':<25}")
print("-" * 95)
for s, g in sorted(groups.items(), key=lambda x: x[1]['net_profit'], reverse=True):
    wr = (g['wins'] / g['trades'] * 100.0) if g['trades'] > 0 else 0.0
    print(f"{s:<24} | {g['trades']:<12d} | {wr:6.1f}%  | ${g['net_profit']:>+14.2f} | {g['best_pair']} (${g['best_pnl']:+.2f})")
