#!/usr/bin/env python3
"""Decode the observed quest.tex as data and parse its declarative DSL.

No game executable, quest script or Python expression is executed. Unknown DSL
expressions remain tokens. The XOR algorithm and literal are from the public
EP3.5 source; the observed input hash is required before decoding.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re

from convert_original_terrain import parse_resource, FormatError

SOURCE_SHA = 'a7d5caab590cc6460c596d89b7c0d6578a21af328a2b66bd2653fd944723a03d'
REFERENCE_COMMIT = '7c3e47ac47844e5c415d356a94d6201a0b9a38c4'
KEY = b'alkdjh flds flsjadhf ;kjdfha;sdflkha;s33'
BLOCK = 65536
TOKEN = re.compile(r"\s+|\x00+|\#[^\n]*|'(?:''|[^'])*'|\$[A-Za-z_][A-Za-z_0-9]*|[A-Za-z_][A-Za-z_0-9]*|[0-9]+|[{}()=;,~+*/&|<>!%\[\].:\-]", re.DOTALL)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def decode(data):
    if len(data) > 16 * 1024**2 or digest(data) != SOURCE_SHA:
        raise FormatError('Unknown quest dataset; refusing to infer encoding')
    return bytes(value ^ KEY[(index % BLOCK) % len(KEY)] for index, value in enumerate(data))


def lex(text):
    tokens = []
    position = 0
    while position < len(text):
        match = TOKEN.match(text, position)
        if match is None:
            raise FormatError('Unsupported quest token at character ' + str(position))
        value = match.group()
        if not value.isspace() and value[0] not in '#\x00':
            tokens.append((value, position, match.end()))
        position = match.end()
        if len(tokens) > 1000000:
            raise FormatError('Quest token count exceeds policy')
    return tokens


class Parser:
    def __init__(self, text):
        self.text = text
        self.tokens = lex(text)
        self.index = 0

    def peek(self):
        return self.tokens[self.index][0] if self.index < len(self.tokens) else None

    def take(self, expected=None):
        if self.index >= len(self.tokens):
            raise FormatError('Unexpected end of quest DSL')
        token = self.tokens[self.index]
        self.index += 1
        if expected is not None and token[0] != expected:
            raise FormatError('Expected ' + expected + ', got ' + token[0])
        return token

    def expression(self, end=';'):
        values, depth = [], 0
        while self.peek() is not None:
            value = self.peek()
            if depth == 0 and value == end:
                break
            value = self.take()[0]
            depth += (value == '(') - (value == ')')
            if depth < 0:
                raise FormatError('Unbalanced quest expression')
            values.append(value)
        if self.peek() is None or depth != 0:
            raise FormatError('Unterminated quest expression')
        return values

    def members(self, depth=0):
        if depth > 16:
            raise FormatError('Quest nesting exceeds policy')
        result = []
        while self.peek() != '}':
            name = self.take()[0]
            if not re.fullmatch(r'[A-Za-z_][A-Za-z_0-9]*', name):
                raise FormatError('Invalid quest member name ' + name)
            if self.peek() == '{':
                self.take('{')
                result.append({'name': name, 'children': self.members(depth + 1)})
                self.take('}')
            else:
                self.take('=')
                result.append({'name': name, 'tokens': self.expression()})
            self.take(';')
        return result

    def parse(self):
        variables, quests = {}, []
        while self.peek() is not None:
            start = self.take()
            name = start[0]
            if name.startswith('$'):
                self.take('=')
                expression = self.expression()
                self.take(';')
                variables[name] = expression
            elif name == 'quest':
                self.take('(')
                identifier = self.expression(')')
                self.take(')')
                self.take('{')
                children = self.members()
                self.take('}')
                end = self.take(';')
                quests.append({'id_tokens': identifier, 'children': children,
                               'start_character': start[1], 'end_character': end[2]})
            else:
                raise FormatError('Unknown top-level quest declaration: ' + name)
        return variables, quests


class Values:
    """Small integer/string expression interpreter; no function execution."""
    def __init__(self, definitions):
        self.definitions = definitions
        self.cache = {'TRUE': 1, 'FALSE': 0, 'ALL': 'ALL'}
        self.active = set()

    def name(self, value):
        if value in self.cache:
            return self.cache[value]
        if value not in self.definitions or value in self.active or len(self.active) > 64:
            raise ValueError('Unresolved or cyclic variable ' + value)
        self.active.add(value)
        try:
            result = self.scalar(self.definitions[value])
            self.cache[value] = result
            return result
        finally:
            self.active.remove(value)

    def scalar(self, tokens):
        index = 0
        precedence = {'|': 1, '&': 2, '+': 3, '-': 3, '*': 4, '/': 4, '%': 4}

        def atom():
            nonlocal index
            if index >= len(tokens):
                raise ValueError('Missing expression value')
            value = tokens[index]
            index += 1
            if value in ['+', '-']:
                number = atom()
                if not isinstance(number, int):
                    raise ValueError('Unary operator requires integer')
                return number if value == '+' else -number
            if value == '(':
                result = expression(0)
                if index >= len(tokens) or tokens[index] != ')':
                    raise ValueError('Unbalanced scalar expression')
                index += 1
                return result
            if value.isdigit():
                return int(value)
            if value.startswith("'"):
                return value[1:-1]  # Native lexer retains literal backslashes.
            return self.name(value)

        def expression(minimum):
            nonlocal index
            left = atom()
            while index < len(tokens) and precedence.get(tokens[index], -1) >= minimum:
                operator = tokens[index]
                priority = precedence[operator]
                index += 1
                right = expression(priority + 1)
                if not isinstance(left, int) or not isinstance(right, int):
                    raise ValueError('Arithmetic requires integers')
                if operator == '+': left += right
                elif operator == '-': left -= right
                elif operator == '*': left *= right
                elif operator == '&': left &= right
                elif operator == '|': left |= right
                elif operator in ['/', '%']:
                    if not right: raise ValueError('Division by zero')
                    quotient = abs(left) // abs(right) * (-1 if (left < 0) != (right < 0) else 1)
                    left = quotient if operator == '/' else left - quotient * right
                if not -(2**63) <= left < 2**63:
                    raise ValueError('Expression integer exceeds policy')
            return left
        result = expression(0)
        if index != len(tokens):
            raise ValueError('Declarative expression is not a scalar')
        return result

    def optional(self, tokens, default=None):
        try:
            return self.scalar(tokens)
        except (ValueError, RecursionError):
            return default


def find(members, name):
    return [member for member in members if member['name'] == name]


def group(members, name):
    matches = find(members, name)
    return matches[0].get('children', []) if matches else []


def field(members, name, values, default=None):
    matches = find(members, name)
    return values.optional(matches[0].get('tokens', []), default) if matches else default


def arguments(tokens):
    """Split only a well-formed single function argument list."""
    if len(tokens) < 3 or tokens[1] != '(' or tokens[-1] != ')':
        return None
    result, current, depth = [], [], 0
    for token in tokens[2:-1]:
        if token == ',' and depth == 0:
            result.append(current); current = []
        else:
            current.append(token)
            depth += (token == '(') - (token == ')')
            if depth < 0: return None
    return result + [current] if depth == 0 else None


def normalize(quest, values):
    members = quest['children']
    basic = group(members, 'BASIC_INFO')
    start = group(members, 'START_REQ')
    actions = group(members, 'START_ACTION')
    requirements = group(members, 'COMPLETION_REQ')
    rewards = group(members, 'COMPLETION_ACTION')
    npc = group(basic, 'QUEST_NPC_INFO')
    identifier = values.scalar(quest['id_tokens'])
    result = {'id': identifier, 'QuestIndex': identifier,
        'title': field(basic, 'QUEST_NAME', values, ''), 'npc_id': field(npc, 'NPC_INDEX', values, 0),
        'description': field(basic, 'DESCRIPTION', values, ''),
        'dialogue': {key.lower(): field(npc, key, values, '') for key in ['PRE_TALK','MID_TALK','SUCCESS_TALK','FAIL_TALK']},
        'prerequisites': [values.optional(item['tokens']) for item in find(start, 'S_REQ_QUEST_INDEX')],
        'objectives': [], 'reward': {'credits': 0, 'experience': field(rewards, 'C_PAY_EXPERIENCE', values, 0)},
        'event_map_id': field(basic, 'EVENT_MAP', values, 0),
        'on_accept': {'warp_map_id': field(actions, 'S_START_MAP_INDEX', values, 0)},
        'on_complete': {'warp_map_id': field(rewards, 'C_PAY_WARP_MAP_INDEX', values, 0)},
        'next_quest_id': field(basic, 'NEXT_QUEST_INDEX', values, 0),
        'start_type': field(basic, 'QUEST_START_TYPE', values), 'end_type': field(basic, 'QUEST_END_TYPE', values),
        'required_influence': field(start, 'S_REQ_INFLUENCE_TYPE', values),
        'required_gear_mask': field(start, 'S_REQ_UNIT_KIND', values),
        'provenance_label': 'Missão original', 'unsupported_requirements': [],
        'dsl_ast': members}
    for item in requirements:
        tokens = item.get('tokens', [])
        if item['name'] == 'C_REQ_ITEM' and 'FROM' in tokens:
            split = tokens.index('FROM')
            count_args = arguments(tokens[:split]); monster_args = arguments(tokens[split + 1:])
            if count_args and monster_args and tokens[split + 1] == 'MONSTER' and len(monster_args) == 3:
                required = values.optional(count_args[0]); code = values.optional(monster_args[0])
                # A one-item, guaranteed drop is equivalent to counting one kill.
                quantity = ''.join(monster_args[1]); probability = values.optional(monster_args[2])
                if isinstance(required, int) and isinstance(code, int) and quantity == '1~1' and probability == 1000000:
                    result['objectives'].append({'kind':'kill','target_code':code,'required':required,
                        'quest_item_num':values.optional(tokens[:1]),'drop_probability':1000000})
                    continue
        result['unsupported_requirements'].append(item)
    if not requirements and result['end_type'] == 0:
        result['objectives'].append({'kind':'dialogue','npc_id':result['npc_id'],'required':1})
    for item in find(rewards, 'C_PAY_ITEM'):
        tokens = item.get('tokens', []); args = arguments(tokens)
        if args and tokens[0] == '$SPI':
            result['reward']['credits'] += values.optional(args[0], 0)
    result['supported_objectives'] = bool(result['objectives']) and not result['unsupported_requirements']
    return result


def export(source, output):
    original = source.read_bytes()
    decoded = decode(original)
    entries, container = parse_resource(decoded)
    if len(entries) != 10 or list(entries) != ['q_%06d' % i for i in range(10)]:
        raise FormatError('Unexpected decoded quest container entry profile')
    definitions, pending = {}, []
    for name, entry in entries.items():
        # A few original strings contain lone legacy bytes. Preserve their byte
        # positions through surrogateescape; publish them as explicit \\xNN text
        # rather than invent a Unicode glyph or emit invalid JSON surrogates.
        text = entry.data.decode('cp949', errors='surrogateescape')
        variables, quests = Parser(text).parse()
        definitions.update(variables)
        byte_offsets = [0]
        for character in text:
            byte_offsets.append(byte_offsets[-1] + len(character.encode('cp949', errors='surrogateescape')))
        for quest in quests:
            start, end = byte_offsets[quest['start_character']], byte_offsets[quest['end_character']]
            quest['_source'] = {'payload_id': name, 'payload_sha256': digest(entry.data),
                'decoded_container_offset': entry.offset + start, 'payload_offset': start,
                'size': end-start, 'sha256': digest(entry.data[start:end])}
            pending.append(quest)
    values = Values(definitions)
    records = []
    for quest in pending:
        record = normalize(quest, values)
        record['_source'] = quest['_source']
        record['QuestName'] = record['title']
        records.append(record)
    identifiers = [record['id'] for record in records]
    if len(identifiers) != len(set(identifiers)):
        raise FormatError('Duplicate original quest IDs; no overwrite applied')
    result = {'schema_version':1, 'source': {'filename':'Res-tex/quest.tex','bytes':len(original),'sha256':digest(original),
        'decoded_container_sha256':digest(decoded), 'reference_commit':REFERENCE_COMMIT,
        'references':['Client/DataRenderLib/main/QuestData.cpp:49-81','Client/EtcLib/main/GameDataLast.cpp:296-319','Client/EtcLib/main/GameDataLast.h:12'],
        'decoding':'native XOR resets each 65536-byte block; public literal from QuestData.cpp',
        'execution':'No quest script executed; bounded declarative parsing only'},
        'container':container, 'definition_count':len(definitions), 'records':records,
        'limits':['Recovered quest content does not recover server spawns, inventory or all special quest actions.',
                  'supported_objectives only marks supported objective syntax; runtime must check map availability and other conditions.']}
    def safe_text(value):
        if isinstance(value, str):
            return ''.join('\\x%02x' % (ord(c)-0xdc00) if 0xdc80 <= ord(c) <= 0xdcff else c for c in value)
        if isinstance(value, list): return [safe_text(item) for item in value]
        if isinstance(value, dict): return {key:safe_text(item) for key,item in value.items()}
        return value
    result = safe_text(result)
    result['source']['text_encoding'] = 'CP949; undecodable original bytes explicitly represented as literal \\xNN, not guessed Unicode'
    output.parent.mkdir(parents=True,exist_ok=True)
    output.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps({'quests':len(records),'definitions':len(definitions),'output':str(output)}))
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source',type=Path)
    parser.add_argument('--output',type=Path,required=True)
    args = parser.parse_args()
    export(args.source,args.output)
