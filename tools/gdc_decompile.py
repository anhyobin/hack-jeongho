#!/usr/bin/env python3
"""
Godot 4.5 GDScript binary-token (.gdc) -> readable GDScript reconstructor.

Godot 4.3+ ships `.gdc` files that are *not* bytecode: they are a serialized
token stream (GDScriptTokenizerBuffer). Because the stream keeps an
identifier table, a constant table and a token->line/column map, the original
source can be reconstructed almost verbatim (comments and exact whitespace are
the only things lost).

Layout (see godot/modules/gdscript/gdscript_tokenizer_buffer.cpp):

    magic  "GDSC"                       4 bytes
    version (must equal 101 for 4.5)    uint32
    decompressed_size                   uint32   (0 => payload is not compressed)
    payload                             zstd frame (or raw when size == 0)

    payload:
      identifier_count                  uint32
      constant_count                    uint32
      token_line_count                  uint32
      token_count                       uint32
      identifiers[]                     uint32 len + len * uint32 (each byte ^ 0xb6)
      constants[]                       encode_variant() blobs
      token_lines[]                     (uint32 token_index, uint32 line)
      token_columns[]                   (uint32 token_index, uint32 column)
      tokens[]                          1 or 4 byte type (+0x80 flag) + uint32 line

Usage:
    python3 gdc_decompile.py scripts_game.gdc [...]      # prints to stdout
    python3 gdc_decompile.py -o outdir scripts/*.gdc     # writes .gd files
"""
import argparse
import os
import struct
import subprocess
import sys
import tempfile

TOKENIZER_VERSION = 101
TOKEN_BYTE_MASK = 0x80
TOKEN_BITS = 8
TOKEN_MASK = (1 << (TOKEN_BITS - 1)) - 1

# Mirrors GDScriptTokenizer::Token::Type ordering in gdscript_tokenizer.h (4.5).
TOKEN_NAMES = [
    "EMPTY", "ANNOTATION", "IDENTIFIER", "LITERAL",
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
    "NEWLINE", "INDENT", "DEDENT",
    "PI", "TAU", "INF", "NAN",
    "VCS_CONFLICT_MARKER", "`", "?",
    "ERROR", "EOF", "TK_MAX",
]

# Tokens that never want a space in front of them.
NO_SPACE_BEFORE = {",", ")", "]", "}", ":", ";", ".", "("}
# Tokens that never want a space after them.
NO_SPACE_AFTER = {"(", "[", ".", "$", "@"}
# `foo[0]` / `foo()[1]` subscript vs. `= [1, 2]` array literal: no space only
# when the previous token can end an expression.
SUBSCRIPTABLE = {")", "]", "}", '"'}


def _decode_variant(b, p):
    header = struct.unpack_from("<I", b, p)[0]
    p += 4
    vtype = header & 0xFFFF
    flag64 = bool(header & (1 << 16))
    if vtype == 0:                                          # NIL
        return None, p
    if vtype == 1:                                          # BOOL
        v = struct.unpack_from("<I", b, p)[0]
        return bool(v), p + 4
    if vtype == 2:                                          # INT
        if flag64:
            return struct.unpack_from("<q", b, p)[0], p + 8
        return struct.unpack_from("<i", b, p)[0], p + 4
    if vtype == 3:                                          # FLOAT
        if flag64:
            return struct.unpack_from("<d", b, p)[0], p + 8
        return struct.unpack_from("<f", b, p)[0], p + 4
    if vtype in (4, 21):                                    # STRING / STRING_NAME
        ln = struct.unpack_from("<I", b, p)[0]
        p += 4
        raw = b[p:p + ln]
        p += ln + ((4 - (ln % 4)) % 4)                      # 4-byte padded
        return raw.decode("utf-8", "replace"), p
    if vtype == 5:                                          # VECTOR2
        return ("Vector2", struct.unpack_from("<ff", b, p)), p + 8
    if vtype == 20:                                         # COLOR
        return ("Color", struct.unpack_from("<ffff", b, p)), p + 16
    raise ValueError("unhandled variant type %d at offset %d" % (vtype, p))


def _zstd_decompress(blob, size):
    try:
        import zstandard                                    # optional fast path
        return zstandard.ZstdDecompressor().decompress(blob, max_output_size=size)
    except ImportError:
        pass
    with tempfile.TemporaryDirectory() as td:
        src, dst = os.path.join(td, "in.zst"), os.path.join(td, "out.bin")
        with open(src, "wb") as f:
            f.write(blob)
        subprocess.run(["zstd", "-d", "-f", "-q", src, "-o", dst], check=True)
        with open(dst, "rb") as f:
            return f.read()


def parse(path):
    """Returns (identifiers, constants, lines, columns, tokens)."""
    data = open(path, "rb").read()
    if data[:4] != b"GDSC":
        raise ValueError("%s: not a GDScript token buffer" % path)
    version = struct.unpack_from("<I", data, 4)[0]
    if version != TOKENIZER_VERSION:
        print("warning: tokenizer version %d (expected %d)" % (version, TOKENIZER_VERSION),
              file=sys.stderr)
    dsize = struct.unpack_from("<I", data, 8)[0]
    buf = _zstd_decompress(data[12:], dsize) if dsize else data[12:]

    ident_count, const_count, line_count, token_count = struct.unpack_from("<IIII", buf, 0)
    p = 16

    identifiers = []
    for _ in range(ident_count):
        ln = struct.unpack_from("<I", buf, p)[0]
        p += 4
        chars = []
        for j in range(ln):
            quad = bytes(x ^ 0xB6 for x in buf[p + j * 4:p + j * 4 + 4])
            chars.append(chr(struct.unpack("<I", quad)[0]))
        p += ln * 4
        identifiers.append("".join(chars))

    constants = []
    for _ in range(const_count):
        value, p = _decode_variant(buf, p)
        constants.append(value)

    lines, columns = {}, {}
    for _ in range(line_count):
        ti, ln = struct.unpack_from("<II", buf, p)
        p += 8
        lines[ti] = ln
    for _ in range(line_count):
        ti, col = struct.unpack_from("<II", buf, p)
        p += 8
        columns[ti] = col

    tokens = []
    for _ in range(token_count):
        if buf[p] & TOKEN_BYTE_MASK:
            raw = struct.unpack_from("<I", buf, p)[0]
            p += 4
        else:
            raw = buf[p]
            p += 1
        line = struct.unpack_from("<I", buf, p)[0]
        p += 4
        tokens.append((raw & TOKEN_MASK, raw >> TOKEN_BITS, line))
    return identifiers, constants, lines, columns, tokens


def _literal(value):
    if isinstance(value, str):
        return '"%s"' % value.replace("\\", "\\\\").replace('"', '\\"')
    if isinstance(value, bool):
        return "true" if value else "false"
    if value is None:
        return "null"
    if isinstance(value, tuple):                            # ("Color", (...))
        return "%s(%s)" % (value[0], ", ".join(repr(round(v, 6)) for v in value[1]))
    return repr(value)


def render(path):
    identifiers, constants, lines, columns, tokens = parse(path)
    out, cur, indent = [], [], 0

    def flush():
        if cur:
            out.append("\t" * indent + "".join(cur).rstrip())
            del cur[:]

    ident_like = ("IDENTIFIER", "LITERAL")
    for i, (ttype, arg, _) in enumerate(tokens):
        name = TOKEN_NAMES[ttype] if ttype < len(TOKEN_NAMES) else "<%d>" % ttype
        if name == "EOF":
            break
        if i in lines:                                      # a new source line starts here
            flush()
            # Godot writes tabs, so column-1 == indent depth for tab-indented source.
            indent = max(0, columns.get(i, 1) - 1)
        if name == "IDENTIFIER":
            text = identifiers[arg]
        elif name == "ANNOTATION":
            text = "@" + identifiers[arg]
        elif name == "LITERAL":
            text = _literal(constants[arg])
        elif name in ("NEWLINE", "INDENT", "DEDENT"):
            continue                                        # not emitted in multiline mode
        else:
            text = name
        if cur:
            prev = cur[-1]
            prev_ends_expr = prev in SUBSCRIPTABLE or prev.endswith('"') or (
                prev[:1].isalnum() or prev[:1] == "_")
            tight = (
                text in NO_SPACE_BEFORE
                or prev in NO_SPACE_AFTER
                or (text == "[" and prev_ends_expr and TOKEN_NAMES[tokens[i - 1][0]] in ident_like
                    or text == "[" and prev in SUBSCRIPTABLE)
                or (text == "=" and prev == ":")          # `var x := 1`
                or (prev == "-" and len(cur) > 1 and cur[-2] in ("(", ",", "=", "<", ">", "["))
            )
            if not tight:
                cur.append(" ")
        cur.append(text)
    flush()
    return "\n".join(out) + "\n"


def main():
    ap = argparse.ArgumentParser(description="Reconstruct GDScript from Godot 4.5 .gdc files")
    ap.add_argument("files", nargs="+")
    ap.add_argument("-o", "--outdir", help="write <name>.gd files here instead of stdout")
    args = ap.parse_args()
    for path in args.files:
        source = render(path)
        if args.outdir:
            os.makedirs(args.outdir, exist_ok=True)
            base = os.path.basename(path)
            base = base[:-4] + ".gd" if base.endswith(".gdc") else base + ".gd"
            dst = os.path.join(args.outdir, base)
            with open(dst, "w") as f:
                f.write(source)
            print("wrote %s (%d lines)" % (dst, source.count("\n")))
        else:
            print("# ---- %s" % path)
            print(source)


if __name__ == "__main__":
    main()
