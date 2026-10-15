#!/usr/bin/env python3
"""Derive an explicitly local stock and conservative native mixing subset."""
import argparse, collections, hashlib, json
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
SAFE_STOCK_KINDS = set(range(11)) | {16,17,18,19,23,25,26}
COUNTABLE_KINDS = {18,19,20,21,23,24,27,28,33,34}
STATEFUL_KINDS = set(range(18)) | {25,26,31,32,35,36,37,38}
# Native NO_TRANSFER, KILL_MARK, timed/deleted-time/GM/cash/account/arena flags;
# explicit local stock selection, not a reconstruction of missing SHOP_ITEM tables.
STOCK_BLOCK_MASK = 0x2 | 0x8 | 0x10 | 0x40 | 0x80 | 0x100 | 0x800 | 0x10000 | 0x20000 | 0x80000 | 0x800000

def derive(items, recipes):
    catalog={int(r['ItemNum']):r for r in items}
    stock=[]
    for n,r in sorted(catalog.items()):
        if r['Kind'] in SAFE_STOCK_KINDS and r['Price']>0 and r['MinTradeQuantity']>0 and not int(r['ItemAttribute'])&STOCK_BLOCK_MASK:
            stock.append(n)
    out=[]
    for index,r in enumerate(recipes):
        target=catalog.get(int(r['TargetItemNum'])); reasons=[]; ingredients=[]
        if r.get('opaque_tail_hex') not in ('00000000','01000000'): reasons.append('unknown_current_recipe_extension')
        if not target: reasons.append('target_item_unavailable')
        elif target['Kind'] not in SAFE_STOCK_KINDS: reasons.append('stateful_target_not_supported')
        elif int(target['ItemAttribute']) & (0x8|0x40|0x80000): reasons.append('timed_target_not_supported')
        totals=collections.Counter()
        for part in r['SourceItem']:
            n,c=int(part['ItemNum']),int(part['Count'])
            if n==0 and c==0: continue
            if n<=0 or c<=0 or n not in catalog: reasons.append('invalid_source_item'); continue
            totals[n]+=c
        if len(totals)!=int(r['NumOfSourceItems']) or not totals: reasons.append('source_count_mismatch')
        for n,c in sorted(totals.items()):
            item=catalog[n]
            if item['Kind'] in STATEFUL_KINDS: reasons.append('source_instance_attributes_not_supported')
            if item['Kind'] not in COUNTABLE_KINDS: reasons.append('source_kind_not_supported')
            ingredients.append({'item_num':n,'count':c})
        if not 0<=int(r['MixingProbability'])<=10000 or not 0<=int(r['MixingCost'])<=1000000000: reasons.append('invalid_native_bounds')
        out.append({'recipe_id':str(index),'item_num':int(r['TargetItemNum']),'count':1,'cost':int(r['MixingCost']),
                    'probability_10k':int(r['MixingProbability']),'native_visible':r.get('opaque_tail_hex')=='01000000','ingredients':ingredients,
                    'supported':not reasons,'reason':next(iter(dict.fromkeys(reasons)),''),
                    'blocking_reasons':list(dict.fromkeys(reasons)), 'source_record_index':index,
                    'source_record_sha256':r['_source']['sha256']})
    return stock,out

def main():
    p=argparse.ArgumentParser();p.add_argument('--output',type=Path,default=ROOT/'client/assets/local_services/economy.json');args=p.parse_args()
    b=ROOT/'client/assets/original_library/catalogs';items=json.loads((b/'items.json').read_text());recipes=json.loads((b/'mixing_recipes.json').read_text())
    stock,rows=derive(items['records'],recipes['records'])
    report={'schema_version':1,'scope':'explicit_local_stock_native_ITEM_prices_conservative_native_mixing',
      'recipe_extension_proof':{'repository':'https://github.com/bhsdp1/AceOnline-ep43','commit':'f880284fafa3af9b4b1a4bb2938efef1b328bb8e','path':'Common/AtumParam.h','line':3911,'file_sha256':'b7bde04448c0b7ef1e44c2d8c7c641dacc385c30cfcb5b2a001ed53bd05fc8c9','interpretation':'ITEM_MIXING_INFO ends with BYTE Visible at offset56 and3padding bytes; tails00000000/01000000 represent hidden/visible.'},
      'native_sources':{n:hashlib.sha256((b/n).read_bytes()).hexdigest() for n in ('items.json','mixing_recipes.json','npc_services.json')},
      'policy':{'stock':'Unlimited local selection by supported native Kind, positive ITEM.Price, valid bundle, no cash/timed/GM/restricted flags. Native SHOP_ITEM stock/prices and tax rates are absent.',
      'buy_price':'ITEM.Price times count/MinTradeQuantity; local zero tax and local stock selection.',
      'sell_price':'int(float32(float32(ITEM.Price) * float32(0.2))) times floor(count/MinTradeQuantity) for native countable kinds; one noncountable unit per sale.',
      'mixing':'Native five ingredients, MixingCost, output count1. One attempt. Source RNG draw0..9999 <= MixingProbability; success/failure both consume ingredients and cost. EP4.3 Visible byte at56 plus3padding decoded for0/1; instance changes and missing ingredients blocked.',
      'repair':'EP3.5 AtumParam.h1973..1976: HP5/DP3/EP1/SP200 per integer point; local zero tax. Ammo: native caliber bundle Price, rounded up; applied amount clamped to runtime magazine.'},
      'stock_item_nums':stock,'native_countable_kinds':sorted(COUNTABLE_KINDS),
      'repair_cost_per_point':{'hp':5,'dp':3,'ep':1,'sp':200},
      'recipes':rows,'summary':{'stock':len(stock),'recipes':len(rows),'supported':sum(x['supported'] for x in rows),'blocked':sum(not x['supported'] for x in rows),'blocking_reasons':dict(collections.Counter(x['reason'] for x in rows if not x['supported']))}}
    args.output.parent.mkdir(parents=True,exist_ok=True);args.output.write_text(json.dumps(report,ensure_ascii=False,separators=(',',':'))+'\n');print(json.dumps(report['summary'],ensure_ascii=False))
if __name__=='__main__':main()
