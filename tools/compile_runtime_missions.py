#!/usr/bin/env python3
"""Compile original declarative quests into a bounded, explicit runtime subset.

Every AST clause is checked. Unsupported clauses produce diagnostic records, not
partial quests. Expressions use the existing bounded Values parser, never eval.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re

from export_original_quests import Parser, Values, decode, arguments
from convert_original_terrain import parse_resource

BASIC_FIELDS = {'QUEST_EPISODE_TYPE','QUEST_INDEX','QUEST_NAME','QUEST_KIND','QUEST_TYPE',
 'QUEST_START_TYPE','QUEST_END_TYPE','QUEST_NPC_INFO','DESCRIPTION','NEXT_QUEST_INDEX',
 'DROP_ITEM_TO_ALL_ATTACK_CHARACTER','DROP_ITEM_TO_ALL_PARTY_MEMBERS','DISCARDABLE_QUEST',
 'TIME_LIMIT_IN_MINUTES','QUEST_PARTYTYPE'}


def definitions(source):
    entries, _ = parse_resource(decode(source.read_bytes()))
    result = {}
    for entry in entries.values():
        parsed, _ = Parser(entry.data.decode('cp949', errors='surrogateescape')).parse()
        result.update(parsed)
    return Values(result)


def compile_one(raw, values):
    out = {key: raw[key] for key in ['id','title','npc_id','dialogue','prerequisites',
        'next_quest_id','start_type','end_type','required_influence','required_gear_mask','_source']}
    out.update({'id': str(raw['id']), 'native': True, 'runtime_supported': False,
        'objectives': [], 'reward': {'credits':0,'experience':0,'items':[],'bonus_stats':0},
        'on_accept': {'warp_map_id':0,'items':[]}, 'on_complete': {'warp_map_id':0},
        'time_limit_seconds':0, 'delete_items':[], 'per_item_rewards':[],
        'random_item_rewards':[], 'inventory_objectives_override_drops':False,
        'external_inventory_items':[],
        'required_level_min':1, 'required_level_max':2147483647, 'blocked_reasons':[],
        'provenance_label':'Missão original; encontros locais identificados',
        'adaptations':['Single-player local authority; original server spawns unavailable']})
    issues = out['blocked_reasons']
    def fail(clause, detail='unsupported_clause'):
        message = clause + ':' + detail
        if message not in issues: issues.append(message)
    def integer(tokens, clause, minimum=0):
        value = values.optional(tokens)
        if not isinstance(value, int) or value < minimum:
            fail(clause, 'unresolved_or_invalid_integer'); return None
        return value
    def simple_item(tokens, clause, allow_all=False):
        mask = 65535
        if 'TO' in tokens:
            split = tokens.index('TO')
            mask = integer(tokens[split+1:],clause,1)
            tokens = tokens[:split]
        args = arguments(tokens)
        if not args or len(args) != 1:
            fail(clause, 'unsupported_item_syntax'); return None
        code = integer(tokens[:1], clause,1)
        count = values.optional(args[0])
        if count == 'ALL' and allow_all: count = -1
        if not isinstance(count,int) or (count <= 0 and not (count == -1 and allow_all)):
            fail(clause, 'unsupported_item_quantity'); return None
        if code is None or mask is None:return None
        return {'item_num':code,'count':count,'gear_mask':mask}
    def area_tokens(tokens, clause):
        """Monster AREA is an original minimap hint, not a kill-radius check.

        QuestLoader.y stores it, INFGameMainMiniMap.cpp displays tile coordinates,
        but FieldCharacterQuest counts monster codes and the completion validator
        does not test the monster's attached MapArea. Preserve that distinction.
        """
        if 'AREA' not in tokens:return tokens, {}
        split=tokens.index('AREA'); tail=tokens[split+1:]
        args=arguments(tail)
        map_tokens=tail[:tail.index('(')] if '(' in tail else tail
        map_id=integer(map_tokens,clause,1)
        area={'map_id':map_id}
        if args:
            if len(args)!=3 or any(not value or value[0]!=key for value,key in zip(args,['X','Y','R'])):
                fail(clause,'unsupported_area_syntax');return tokens[:split],{}
            for value,key in zip(args,['x','y','radius']):
                area[key]=integer(value[1:],clause)
        elif len(tail)!=1:
            fail(clause,'unsupported_area_syntax')
        return tokens[:split],area
    seen_groups = set()
    quest_items = set()
    pending_deletes = []
    for section in raw.get('dsl_ast',[]):
        name = section.get('name','')
        if name in seen_groups: fail(name,'duplicate_section')
        seen_groups.add(name)
        if name not in ['BASIC_INFO','START_REQ','START_ACTION','COMPLETION_REQ','COMPLETION_ACTION']:
            fail(name); continue
        for clause in section.get('children',[]):
            key = clause.get('name',''); tokens = clause.get('tokens',[])
            if name == 'BASIC_INFO':
                if key not in BASIC_FIELDS:fail(key)
                if key == 'TIME_LIMIT_IN_MINUTES':
                    minutes=integer(tokens,key)
                    if minutes is not None and minutes<=10080:out['time_limit_seconds']=minutes*60
                    elif minutes is not None:fail(key,'time_limit_out_of_bounds')
                if key == 'QUEST_PARTYTYPE' and values.optional(tokens,1) != 0:fail(key,'party_missions_require_server')
                if key == 'QUEST_TYPE' and values.optional(tokens) not in [0,1]:fail(key,'repeatability_not_implemented')
                if key == 'QUEST_NPC_INFO':
                    allowed = {'NPC_INDEX','PRE_TALK','MID_TALK','SUCCESS_TALK','FAIL_TALK'}
                    for npc in clause.get('children',[]):
                        if npc.get('name') not in allowed:fail(npc.get('name','UNKNOWN_NPC_FIELD'))
            elif name == 'START_REQ':
                if key in ['S_REQ_INFLUENCE_TYPE','S_REQ_UNIT_KIND','S_REQ_QUEST_INDEX']:
                    value = integer(tokens,key)
                    if key == 'S_REQ_INFLUENCE_TYPE':out['required_influence']=value
                    elif key == 'S_REQ_UNIT_KIND':out['required_gear_mask']=value
                elif key == 'S_REQ_LEVEL':
                    # Only the exact observed bounded/open range grammar is legal.
                    if len(tokens) >= 4 and tokens[0]=='(' and tokens[-1]==')' and tokens.count('~')==1:
                        split=tokens.index('~'); low=integer(tokens[1:split],key)
                        high=integer(tokens[split+1:-1],key) if split+1<len(tokens)-1 else 2147483647
                        if low is not None and high is not None and low<=high:
                            out['required_level_min']=low;out['required_level_max']=high
                        else:fail(key,'invalid_level_range')
                    else:fail(key,'unsupported_level_syntax')
                elif key == 'S_START_PARTY_WARP_FLAG':
                    if values.optional(tokens) not in [0,1]:fail(key,'invalid_boolean')
                    out['adaptations'].append('Party-warp flag has no other members in this local solo session')
                else:fail(key)
            elif name == 'START_ACTION':
                if key == 'S_START_MAP_INDEX':
                    value=integer(tokens,key)
                    if value is not None:out['on_accept']['warp_map_id']=value
                elif key == 'S_START_PARTY_WARP_FLAG':
                    if values.optional(tokens) not in [0,1]:fail(key,'invalid_boolean')
                    out['adaptations'].append('Party-warp flag has no other members in this local solo session')
                elif key == 'S_PAY_ITEM':
                    item=simple_item(tokens,key)
                    if item:out['on_accept']['items'].append(item)
                else:fail(key)
            elif name == 'COMPLETION_REQ':
                if key == 'C_REQ_MONSTER':
                    tokens,area=area_tokens(tokens,key)
                    args=arguments(tokens)
                    if not args or len(args)!=1:
                        fail(key,'area_or_complex_monster_condition_not_implemented');continue
                    code=integer(tokens[:1],key,1);required=integer(args[0],key,1)
                    if code is not None and required is not None:
                        objective={'kind':'kill','target_code':code,'monster_code':code,'required':required}
                        if area:objective['source_area']=area
                        out['objectives'].append(objective)
                elif key == 'C_REQ_ITEM' and 'FROM' in tokens:
                    tokens,area=area_tokens(tokens,key)
                    split=tokens.index('FROM');count_args=arguments(tokens[:split]);monster_args=arguments(tokens[split+1:])
                    if not count_args or not monster_args or tokens[split+1]!='MONSTER' or len(monster_args)!=3:
                        fail(key,'area_or_complex_drop_condition_not_implemented');continue
                    count=integer(count_args[0],key,-1);code=integer(monster_args[0],key,1)
                    item=integer(tokens[:1],key);probability=integer(monster_args[2],key)
                    span=monster_args[1]
                    if span.count('~')!=1:fail(key,'unsupported_drop_range');continue
                    boundary=span.index('~');low=integer(span[:boundary],key);high=integer(span[boundary+1:],key)
                    if None not in [low,high] and (low>high or high>1000000):fail(key,'invalid_drop_range')
                    # Item0/Count-1 are native minimap-only hints and never objectives.
                    if item==0 and count==-1:continue
                    if item==0 or count is not None and count<=0:fail(key,'zero_or_negative_quantity_requires_unbounded_collection');continue
                    if None not in [count,code,item,probability,low,high]:
                        quest_items.add(item)
                        objective={'kind':'kill','target_code':code,'monster_code':code,'required':count,'quest_item_num':item,'drop_probability':probability}
                        # Keep v0.6's guaranteed one-item objectives byte-compatible.
                        if low!=1 or high!=1:objective.update(drop_min=low,drop_max=high)
                        if area:objective['source_area']=area
                        out['objectives'].append(objective)
                elif key in ['C_REQ_ITEM','C_REQ_MIX_ITEM_TARGET']:
                    item=simple_item(tokens,key)
                    if item:
                        out['objectives'].append({'kind':'inventory','item_num':item['item_num'],'required':item['count']})
                        if key=='C_REQ_MIX_ITEM_TARGET':out['inventory_objectives_override_drops']=True
                elif key == 'C_REQ_USE_ITEM':
                    fail(key,'native_clause_semantics_absent_from_pinned_sources')
                elif key == 'C_REQ_MEET_OBJ_INDEX' and 'AREA' in tokens:
                    split=tokens.index('AREA');event=integer(tokens[:split],key,1);map_id=integer(tokens[split+1:],key,1)
                    if event is not None and map_id is not None:
                        out['objectives'].append({'kind':'visit_event','event_id':event,'map_id':map_id,'required':1})
                        out['adaptations'].append('Visit trigger uses local120-unit proximity to the original event; native server warp-target validation is not reproduced')
                else:fail(key)
            elif name == 'COMPLETION_ACTION':
                if key == 'C_PAY_ITEM':
                    per_item=0
                    if 'PER' in tokens:
                        split=tokens.index('PER');per_item=integer(tokens[split+1:],key,1);tokens=tokens[:split]
                    item=simple_item(tokens,key)
                    if item:
                        # SPI is a real item constant in the original script.
                        if per_item:
                            out['per_item_rewards'].append({'source_item_num':per_item,'credits':item['count'] if tokens[:1]==['$SPI'] else 0,'item_num':0 if tokens[:1]==['$SPI'] else item['item_num'],'count':item['count'],'gear_mask':item['gear_mask']})
                        elif tokens[:1] == ['$SPI']:out['reward']['credits']+=item['count']
                        else:out['reward']['items'].append(item)
                elif key == 'C_RANDOM_PAY_ITEM':
                    # Native weighted OR list, optionally repeated PER proof item.
                    per_item=0
                    if 'PER' in tokens:
                        split=tokens.index('PER');per_item=integer(tokens[split+1:],key,1);tokens=tokens[:split]
                    groups=[];start=0
                    for index,token in enumerate(tokens):
                        if token=='OR':groups.append(tokens[start:index]);start=index+1
                    groups.append(tokens[start:]);choices=[]
                    for group in groups:
                        args=arguments(group)
                        if not args or len(args)!=2:fail(key,'unsupported_weighted_reward');continue
                        code=integer(group[:1],key,1);count=integer(args[0],key,1);weight=integer(args[1],key,1)
                        if None not in [code,count,weight]:choices.append({'item_num':code,'count':count,'weight':weight})
                    if choices:out['random_item_rewards'].append({'source_item_num':per_item,'choices':choices})
                elif key == 'C_PAY_EXPERIENCE':
                    value=integer(tokens,key)
                    if value is not None:out['reward']['experience']+=value
                elif key == 'C_PAY_BONUS_STAT':
                    value=integer(tokens,key)
                    if value is not None:out['reward']['bonus_stats']+=value
                elif key == 'C_PAY_WARP_MAP_INDEX':
                    value=integer(tokens,key)
                    if value is not None:out['on_complete']['warp_map_id']=value
                elif key == 'C_DEL_ITEM':
                    item=simple_item(tokens,key,True)
                    if item:pending_deletes.append(item)
                else:fail(key)
    if raw.get('start_type') != 2:fail('QUEST_START_TYPE','only_meet_npc_supported')
    if raw.get('end_type') not in [0,1]:fail('QUEST_END_TYPE','unsupported_completion_trigger')
    if not out['objectives'] and raw.get('end_type')==0:
        out['objectives']=[{'kind':'dialogue','npc_id':int(raw.get('npc_id',0)),'required':1}]
    if not out['objectives']:fail('COMPLETION_REQ','no_supported_objectives')
    # FieldIOCPSocket.cpp:29179,29224,29397 reads PER/deletions from the
    # existing inventory, independently of this quest's TargetMonsterItemVector.
    # An absent item yields no variable reward/deletion; it is not an unmet
    # completion requirement. Never synthesize a missing global monster drop.
    local_items = quest_items | {item['item_num'] for item in out['on_accept']['items']}
    local_items |= {objective['item_num'] for objective in out['objectives'] if 'item_num' in objective}
    out['delete_items'] = pending_deletes
    inventory_items = {item['item_num'] for item in pending_deletes}
    inventory_items |= {reward['source_item_num'] for reward in out['per_item_rewards']+out['random_item_rewards'] if reward['source_item_num']}
    out['external_inventory_items'] = sorted(inventory_items - local_items)
    if out['external_inventory_items']:
        out['adaptations'].append('Native optional PER rewards and C_DEL_ITEM read synchronized inventory; eligible recovered server drops are handled separately, and absent or unsupported drops are never invented')
    if any('source_area' in objective for objective in out['objectives']):
        out['adaptations'].append('Monster AREA is preserved as native tile-coordinate navigation hint; the pinned server validates code counts, not this marker radius')
    if any(objective.get('drop_probability',1000000)!=1000000 or objective.get('drop_min',1)!=1 or objective.get('drop_max',1)!=1 for objective in out['objectives']):
        out['adaptations'].append('Native drop probability/range; local persisted deterministic RNG, without server event/drop-rate modifiers')
    if out['time_limit_seconds']:
        out['adaptations'].append('Native time limit measured in local active simulation time; offline/paused time does not advance')
    if None in out['prerequisites']:fail('S_REQ_QUEST_INDEX','unresolved_prerequisite')
    out['event_map_id']=out['on_accept']['warp_map_id']
    out['runtime_supported']=not issues
    return out


def compile_catalog(catalog, values):
    records=[compile_one(record, values) for record in catalog['records']]
    return {'schema_version':2,'compiler':'bounded_ast_clause_allowlist_v3',
        'source_sha256':catalog['source']['sha256'],
        'source_catalog_sha256':None,
        'records':records,
        'summary':{'total':len(records),'supported':sum(r['runtime_supported'] for r in records),
            'blocked':sum(not r['runtime_supported'] for r in records)},
        'limits':['Supported syntax is distinct from playable availability: maps, event positions and monster models are checked by the runtime.',
            'Native random drops, attached monster minimap areas, inventory conditions and active-play timers are supported; party/PvP and clauses absent from pinned sources remain blocked.',
            'Source content and rewards are preserved; NPC positions and enemy encounters are labeled local adaptations.']}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--catalog',type=Path,default=Path('client/assets/legacy_rules/missions.json'))
    parser.add_argument('--source',type=Path,default=Path('docs/evidence/quest-native.tex'))
    parser.add_argument('--output',type=Path,default=Path('client/assets/local_world/mission_support.json'))
    args=parser.parse_args()
    catalog=json.loads(args.catalog.read_text())
    result=compile_catalog(catalog,definitions(args.source))
    result['source_catalog_sha256']=hashlib.sha256(args.catalog.read_bytes()).hexdigest()
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(result,ensure_ascii=False,separators=(',',':'))+'\n')
    print(json.dumps(result['summary']))

if __name__=='__main__':main()
