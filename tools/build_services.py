#!/usr/bin/env python3
"""Compile compatible recovered shop membership and conservative native mixing."""
import argparse, collections, hashlib, json
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
SAFE_STOCK_KINDS = set(range(11)) | {16,17,18,19,23,25,26}
COUNTABLE_KINDS = {18,19,20,21,23,24,27,28,33,34}
STATEFUL_KINDS = set(range(18)) | {25,26,31,32,35,36,37,38}
# Native NO_TRANSFER, KILL_MARK, timed/deleted-time/GM/cash/account/arena flags;
# fallback local selection and native membership both exclude these flags.
STOCK_BLOCK_MASK = 0x2 | 0x8 | 0x10 | 0x40 | 0x80 | 0x100 | 0x800 | 0x10000 | 0x20000 | 0x80000 | 0x800000
# These fields must agree across the legacy SQL backup and the current client.
# A shared ItemNum alone does not establish that two versions sell the same item.
SHOP_COMPATIBILITY_FIELDS = ('Kind','SourceIndex','Position','ReqUnitKind','ReqMinLevel',
                             'ReqMaxLevel','MinTradeQuantity','Price','Caliber')
SPI_SHOP_KINDS = {0,1,2,3,4,35,36,37}

def table_records(table):
    """Read the compact static-table export, without evaluating database content."""
    columns=table['columns']
    if not isinstance(columns,list) or len(columns)!=len(set(columns)):
        raise ValueError('Invalid native table columns')
    records=[]
    for row in table['rows']:
        if len(row)!=len(columns):
            raise ValueError('Invalid native table row length')
        records.append(dict(zip(columns,row)))
    return records

def compile_native_shops(items, current_buildings, shop_table, building_table, item_table):
    """Recover shop membership only when NPC identity and ITEM economics agree.

    FieldMapProject.cpp's atum_GetAllShopItems joins ti_Shop.UniqueNumber to
    ti_BuildingNPC.BuildingIndex and ti_Shop.ItemNum to ti_Item.ItemNum. The
    active loader orders by ShopOrder. ti_Shop carries no price or tax column.
    """
    current={int(row['ItemNum']):row for row in items}
    legacy_rows=table_records(item_table)
    invalid_legacy_item_ids=sum(not isinstance(row['ItemNum'],int) or row['ItemNum']<=0 for row in legacy_rows)
    legacy={row['ItemNum']:row for row in legacy_rows if isinstance(row['ItemNum'],int) and row['ItemNum']>0}
    buildings={int(row['BuildingIndex']):row for row in table_records(building_table)}
    matching_buildings={int(row['BuildingIndex']):row for row in current_buildings}
    grouped=collections.defaultdict(list); rejected=collections.Counter()
    rows=table_records(shop_table)
    for index,row in enumerate(rows):
        building=int(row['UniqueNumber']); number=int(row['ItemNum'])
        old_building=buildings.get(building); new_building=matching_buildings.get(building)
        if old_building is None or new_building is None:
            rejected['building_unavailable']+=1;continue
        old_kind=int(old_building['BuildingKind']); new_kind=int(new_building['BuildingKind'])
        # EP4.3 added titles/categories for existing SPI shops. Its item-list
        # switch handles35/36/37 together with0..4; this is an explicit,
        # source-proven version migration, not a fuzzy NPC/name match.
        same_kind=old_kind==new_kind or (old_kind==0 and new_kind in {35,36,37})
        if not same_kind or any(int(old_building[k])!=int(new_building[k]) for k in ('MapIndex','NPCIndex')):
            rejected['building_version_mismatch']+=1;continue
        if old_kind not in SPI_SHOP_KINDS or new_kind not in SPI_SHOP_KINDS:
            rejected['non_spi_shop_kind']+=1;continue
        old=legacy.get(number); new=current.get(number)
        if old is None or new is None:
            rejected['item_unavailable']+=1;continue
        if any(k not in old or k not in new or old[k]!=new[k] for k in SHOP_COMPATIBILITY_FIELDS):
            rejected['item_version_mismatch']+=1;continue
        if int(new['Kind']) not in SAFE_STOCK_KINDS or int(new['Price'])<=0 or int(new['MinTradeQuantity'])<=0:
            rejected['unsupported_item_economy']+=1;continue
        if old.get('ItemAttribute') is None or new.get('ItemAttribute') is None or (int(old['ItemAttribute'])|int(new['ItemAttribute']))&STOCK_BLOCK_MASK:
            rejected['restricted_item_flags']+=1;continue
        grouped[building].append((int(row['ShopOrder']),index,number))
    shops=[]
    for building,stock in sorted(grouped.items()):
        native=buildings[building];current_building=matching_buildings[building];seen=set();entries=[]
        for order,index,number in sorted(stock):
            if number in seen: continue
            seen.add(number)
            entries.append({'item_num':number,'shop_order':order,'source_row_index':index})
        shops.append({'building_index':building,'map_id':int(native['MapIndex']),
                      'building_kind':int(current_building['BuildingKind']),'legacy_building_kind':int(native['BuildingKind']),
                      'npc_index':int(native['NPCIndex']),
                      'entries':entries})
    return {'schema_version':1,'compatibility_fields':list(SHOP_COMPATIBILITY_FIELDS),
            'shops':shops,'summary':{'source_rows':len(rows),'shops':len(shops),
                'invalid_legacy_item_ids':invalid_legacy_item_ids,
                'accepted_rows':sum(len(s['entries']) for s in shops),
                'unique_items':len({r['item_num'] for s in shops for r in s['entries']}),
                'rejected_rows':dict(sorted(rejected.items()))},
            'policy':'Legacy ti_Shop membership and ShopOrder; exact NPC and ITEM compatibility required. '
                     'Price and MinTradeQuantity agree in both versions. No restored stock limits or faction taxes; local zero tax.',
            'source_proof':{'repository':'https://github.com/bhsdp1/AceOnline-ep35','commit':'7c3e47ac47844e5c415d356a94d6201a0b9a38c4',
                'join':'ti_Shop.UniqueNumber = ti_BuildingNPC.BuildingIndex; ti_Shop.ItemNum = ti_Item.ItemNum',
                'loader':{'path':'Server/GameServer/FieldServer/Main/FieldMapProject.cpp',
                    'lines':'434-436,545-565','sha256':'d0abbbbb6ed894ca22efa8f002c74363ec3876b6951b17acc690848a9882e20c'},
                'purchase':{'path':'Server/GameServer/FieldServer/Main/FieldIOCPSocket2.cpp',
                    'lines':'167-171,377-385','sha256':'80dcef7caea5d990e601eba69c36c8babda5c4661573e52d023531aa40f0d33e'},
                'category_migration':{'repository':'https://github.com/bhsdp1/AceOnline-ep43',
                    'commit':'f880284fafa3af9b4b1a4bb2938efef1b328bb8e',
                    'path':'ProjectsServer/GameServer/FieldServer/Main/FieldIOCPSocket2.cpp',
                    'sha256':'11928737c13233fe611f6925b6bed913f771dd9285e799a5e7cc706ec970c21f',
                    'lines':'547-563','rule':'Legacy SPI shop kind0 may match EP4.3 title categories35/36/37 with unchanged BuildingIndex, MapIndex and NPCIndex.'}}}

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
    p=argparse.ArgumentParser();p.add_argument('--output',type=Path,default=ROOT/'client/assets/local_services/economy.json')
    p.add_argument('--native-source',type=Path,default=ROOT/'client/assets/native_server');args=p.parse_args()
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
    if args.native_source.is_dir():
        tables={name:json.loads((args.native_source/(name+'.json')).read_text())
                for name in ('ti_Shop','ti_BuildingNPC','ti_Item')}
        shops=compile_native_shops(items['records'],json.loads((b/'npc_services.json').read_text())['records'],
                                   tables['ti_Shop'],tables['ti_BuildingNPC'],tables['ti_Item'])
        shops['source_sha256']={name:hashlib.sha256((args.native_source/(name+'.json')).read_bytes()).hexdigest() for name in tables}
        report['native_shops']=shops
        report['stock_item_nums']=sorted({r['item_num'] for s in shops['shops'] for r in s['entries']})
        report['summary']['stock']=len(report['stock_item_nums'])
        report['summary']['native_shops']=shops['summary']
        report['scope']='verified_legacy_shop_membership_compatible_current_ITEM_native_mixing'
        report['policy']['stock']=shops['policy']
        report['policy']['buy_price']='Compatible native shop required; matching legacy/current ITEM.Price times count/MinTradeQuantity; local zero tax.'
    args.output.parent.mkdir(parents=True,exist_ok=True);args.output.write_text(json.dumps(report,ensure_ascii=False,separators=(',',':'))+'\n');print(json.dumps(report['summary'],ensure_ascii=False))
if __name__=='__main__':main()
