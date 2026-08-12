#!/usr/bin/env python3
"""Decompile Godot 4.7 binary-token GDScript (.gdc, magic GDSC) back to source.

Format reference: modules/gdscript/gdscript_tokenizer_buffer.cpp (Godot 4.7).
Header: "GDSC" | u32 tokenizer_version | u32 decompressed_size | zstd payload
Payload: u32 identifier_count, constant_count, token_line_count, token_count
         identifiers (u32 len + len*u32 codepoints XOR 0xb6)
         constants (encode_variant stream)
         token_lines   (token_line_count * (u32 idx, u32 line))
         token_columns (token_line_count * (u32 idx, u32 col))
         tokens (5 or 8 bytes each; 0x80 flag on first byte => 8 bytes w/ value idx)
"""
import re
import struct
import sys
from compression import zstd

TOKEN_NAMES = [
    "Empty",
    "Annotation", "Identifier", "Literal",
    "<", "<=", ">", ">=", "==", "!=",
    "and", "or", "not", "&&", "||", "!",
    "&", "|", "~", "^", "<<", ">>",
    "+", "-", "*", "**", "/", "%",
    "=", "+=", "-=", "*=", "**=", "/=", "%=", "<<=", ">>=", "&=", "|=", "^=",
    "if", "elif", "else", "for", "while", "break", "continue", "pass", "return",
    "match", "when",
    "as", "assert", "await", "breakpoint", "class", "class_name", "const",
    "enum", "extends", "func", "in", "is", "namespace", "preload", "self",
    "signal", "static", "super", "trait", "var", "void", "yield",
    "[", "]", "{", "}", "(", ")", ",", ";", ".", "..", "...", ":", "$", "->", "_",
    "Newline", "Indent", "Dedent",
    "PI", "TAU", "INF", "NaN",
    "VCS conflict marker", "`", "?",
    "Error", "End of file",
]
T = {name: i for i, name in enumerate(TOKEN_NAMES)}
ANNOTATION, IDENTIFIER, LITERAL = 1, 2, 3

ENCODE_MASK = 0xFF
ENCODE_FLAG_64 = 1 << 16

VARIANT_NIL, VARIANT_BOOL, VARIANT_INT, VARIANT_FLOAT = 0, 1, 2, 3
VARIANT_STRING, VARIANT_STRING_NAME, VARIANT_NODE_PATH = 4, 21, 22


def decode_string(buf, pos):
    (n,) = struct.unpack_from('<I', buf, pos)
    pos += 4
    s = buf[pos:pos + n].decode('utf-8', 'replace')
    pad = (4 - n % 4) % 4
    return s, 4 + n + pad


def decode_variant(buf, pos):
    """Return (value, consumed_bytes). Mirrors core/io/marshalls.cpp."""
    (header,) = struct.unpack_from('<I', buf, pos)
    vtype = header & ENCODE_MASK
    wide = bool(header & ENCODE_FLAG_64)
    p = pos + 4
    if vtype == VARIANT_NIL:
        return None, 4
    if vtype == VARIANT_BOOL:
        (v,) = struct.unpack_from('<I', buf, p)
        return bool(v), 8
    if vtype == VARIANT_INT:
        if wide:
            return struct.unpack_from('<q', buf, p)[0], 12
        return struct.unpack_from('<i', buf, p)[0], 8
    if vtype == VARIANT_FLOAT:
        if wide:
            return struct.unpack_from('<d', buf, p)[0], 12
        return struct.unpack_from('<f', buf, p)[0], 8
    if vtype in (VARIANT_STRING, VARIANT_STRING_NAME, VARIANT_NODE_PATH):
        s, n = decode_string(buf, p)
        kind = {VARIANT_STRING: 'String', VARIANT_STRING_NAME: 'StringName',
                VARIANT_NODE_PATH: 'NodePath'}[vtype]
        return (kind, s), 4 + n
    raise NotImplementedError(f"variant type {vtype} (header {header:#x}) at {pos}")


def literal_repr(v):
    if v is None:
        return 'null'
    if isinstance(v, bool):
        return 'true' if v else 'false'
    if isinstance(v, tuple):
        kind, s = v
        body = '"' + s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n').replace('\t', '\\t') + '"'
        if kind == 'StringName':
            return '&' + body
        if kind == 'NodePath':
            return '^' + body
        return body
    if isinstance(v, float):
        r = repr(v)
        return r
    return repr(v)


def parse(path):
    raw = open(path, 'rb').read()
    assert raw[:4] == b'GDSC', raw[:4]
    version, dsize = struct.unpack_from('<II', raw, 4)
    body = zstd.decompress(raw[12:]) if dsize else raw[12:]
    assert not dsize or len(body) == dsize, (len(body), dsize)

    ident_count, const_count, line_count, token_count = struct.unpack_from('<IIII', body, 0)
    pos = 16

    identifiers = []
    for _ in range(ident_count):
        (n,) = struct.unpack_from('<I', body, pos)
        pos += 4
        chunk = bytes(b ^ 0xB6 for b in body[pos:pos + n * 4])
        pos += n * 4
        cps = struct.unpack(f'<{n}I', chunk)
        identifiers.append(''.join(chr(c) for c in cps))

    constants = []
    for _ in range(const_count):
        v, n = decode_variant(body, pos)
        pos += n
        constants.append(v)

    token_lines = {}
    for _ in range(line_count):
        idx, line = struct.unpack_from('<II', body, pos)
        pos += 8
        token_lines[idx] = line
    token_cols = {}
    for _ in range(line_count):
        idx, col = struct.unpack_from('<II', body, pos)
        pos += 8
        token_cols[idx] = col

    tokens = []
    for _ in range(token_count):
        first = body[pos]
        if first & 0x80:
            (word,) = struct.unpack_from('<I', body, pos)
            ttype = word & 0x7F
            value_idx = word >> 8
            (line,) = struct.unpack_from('<I', body, pos + 4)
            pos += 8
        else:
            ttype = first & 0x7F
            value_idx = None
            (line,) = struct.unpack_from('<I', body, pos + 1)
            pos += 5
        tokens.append((ttype, value_idx, line))

    leftover = len(body) - pos
    return {
        'version': version, 'identifiers': identifiers, 'constants': constants,
        'token_lines': token_lines, 'token_cols': token_cols, 'tokens': tokens,
        'leftover': leftover,
    }


NO_SPACE_BEFORE = {',', ';', ')', ']', '}', ':', '.', '..', '...'}
NO_SPACE_AFTER = {'(', '[', '.', '..', '...', '$', '~'}
UNARY_CONTEXT = {'(', '[', '{', ',', '=', '+=', '-=', '*=', '/=', '%=', '**=',
                 '+', '-', '*', '/', '%', '**', '<', '>', '<=', '>=', '==', '!=',
                 'and', 'or', 'not', 'return', 'if', 'elif', 'while', 'in', ':',
                 '&', '|', '^', '<<', '>>', 'await'}
KEYWORDS_NEED_SPACE = {'if', 'elif', 'while', 'for', 'return', 'in', 'and', 'or',
                       'not', 'is', 'as', 'await', 'assert', 'match', 'when',
                       'var', 'const', 'func', 'class', 'class_name', 'extends',
                       'signal', 'enum', 'static', 'else', 'print'}


def render(info, use_tabs=None):
    tokens = info['tokens']
    idents = info['identifiers']
    consts = info['constants']
    lines_map = info['token_lines']
    cols_map = info['token_cols']

    indents = sorted({c - 1 for c in cols_map.values()})
    if use_tabs is None:
        non_zero = [i for i in indents if i > 0]
        use_tabs = bool(non_zero) and min(non_zero) == 1
    unit = 1 if use_tabs else 4
    pad_char = '\t' if use_tabs else ' '

    out = []          # list of (line_no, text)
    cur_tokens = []   # list of token text on current line
    cur_indent = 0
    cur_line = lines_map.get(0, 1)

    def text_of(ttype, value_idx):
        if ttype in (IDENTIFIER, ANNOTATION):
            return idents[value_idx]
        if ttype == LITERAL:
            return literal_repr(consts[value_idx])
        if ttype == T['Error']:
            return f"<error {literal_repr(consts[value_idx])}>"
        return TOKEN_NAMES[ttype]

    def flush():
        if not cur_tokens:
            return
        buf = ''
        prev = None
        for tok in cur_tokens:
            if buf:
                need = True
                if tok in NO_SPACE_BEFORE:
                    need = False
                elif prev in NO_SPACE_AFTER:
                    need = False
                elif tok == '(' and prev is not None and prev not in KEYWORDS_NEED_SPACE and (
                        prev.replace('_', 'a').isalnum() or prev in (')', ']', '"')):
                    need = False
                elif tok == '[' and prev is not None and (
                        prev.replace('_', 'a').isalnum() or prev in (')', ']', '"')):
                    need = False
                elif prev in ('-', '+', '!', '~') and prev_prev_unary[0]:
                    need = False
                elif tok == '=' and prev == ':':
                    need = False
                elif tok == ':':
                    need = False
                if need:
                    buf += ' '
            prev_prev_unary[0] = (prev in UNARY_CONTEXT) if prev else True
            buf += tok
            prev = tok
        out.append((cur_line, pad_char * (cur_indent * (1 if use_tabs else 1)) + buf))

    prev_prev_unary = [True]
    for i, (ttype, value_idx, line) in enumerate(tokens):
        if ttype == T['End of file']:
            break
        if i in lines_map:
            flush()
            cur_tokens = []
            cur_line = lines_map[i]
            col = cols_map.get(i, 1)
            cur_indent = (col - 1) // unit if unit else 0
        if ttype in (T['Newline'], T['Indent'], T['Dedent'], T['Empty']):
            continue
        cur_tokens.append(text_of(ttype, value_idx))
    flush()

    # Re-emit with blank lines preserved from original line numbers.
    result = []
    last = 0
    for line_no, text in out:
        while last + 1 < line_no:
            result.append('')
            last += 1
        result.append(text)
        last = line_no
    text = '\n'.join(result) + '\n'
    text = re.sub(r'(\w):=', r'\1 :=', text)  # cosmetic: `var x:= 1` -> `var x := 1`
    return text, use_tabs


if __name__ == '__main__':
    for path in sys.argv[1:]:
        info = parse(path)
        src, use_tabs = render(info)
        out_path = path[:-4] + '.decompiled.gd' if path.endswith('.gdc') else path + '.gd'
        open(out_path, 'w').write(src)
        print(f"{path}: tokenizer_v{info['version']} idents={len(info['identifiers'])} "
              f"consts={len(info['constants'])} tokens={len(info['tokens'])} "
              f"leftover={info['leftover']} tabs={use_tabs} -> {out_path}")
