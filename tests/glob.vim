vim9script

# Conformance test for EditorConfig section globs.
#
# The table below is checked case by case against the reference implementation,
# editorconfig-core-py 0.17.1, driven the same way it drives itself: one
# .editorconfig holding one section, one property, and a file path asked for its
# properties.  Every entry here agrees with that reference except for three
# deviations, each marked where it appears:
#
#   * `\x` escapes x.  The reference honours a backslash only before a comma or
#     a brace, so it reads `\*.c` as `*.c` and matches every C file in the tree;
#     the spec, ec4rs and editorconfig-core-rs all read it as the file named
#     `*.c`, and so do we.
#   * `{-2..2}` matches the name `0`.  The reference rejects any captured number
#     whose first digit is `0`, which was meant to keep `007` out of `{1..100}`
#     — that part we keep — but it also throws away plain `0`.  Both Rust
#     implementations match `0`.
#   * `\{a\}.c` names the file `{a}.c`.  The reference builds an unbalanced
#     regex from it and raises re.error instead of answering.
#
# Cases are [pattern, paths it must match, paths it must not match]; paths are
# relative to the directory holding the .editorconfig.

set nocompatible nomore
const ROOT = fnamemodify(resolve(expand('<sfile>:p')), ':h:h')
execute 'set runtimepath^=' .. fnameescape(ROOT)
execute 'source ' .. fnameescape(ROOT .. '/plugin/simpleeditorconfig.vim')

const CASES: list<list<any>> = [
  # The four wrong answers glob2regpat() used to give, one case each.
  # `*` never crosses a separator.
  ['lib/*.c', ['lib/x.c', 'lib/xy.c'], ['lib/deep/x.c', 'lib/deep/nested/x.c']],
  # `[!abc]` is a negation, not a collection containing `!`.
  ['[!abc].c', ['d.c', 'z.c', '].c'], ['a.c', 'b.c', 'c.c']],
  # `{n..m}` is an integer range, not the literal text `n..m`.
  ['test_{1..9}.py', ['test_1.py', 'test_5.py', 'test_9.py'],
    ['test_0.py', 'test_10.py', 'test_x.py']],
  # A brace group with no comma in it is part of the file's name.
  ['a{b}c.txt', ['a{b}c.txt'], ['abc.txt', 'ac.txt']],
  # And the fifth symptom, from the missing `^`: a pattern beginning with `*`
  # compiled to an unanchored regex, so `*/foo.c` reached any depth at all.
  ['*/foo.c', ['a/foo.c', 'lib/foo.c'], ['foo.c', 'deep/nested/foo.c']],

  # Anchoring.  A pattern with no separator matches the name at any depth; one
  # with a separator is anchored to the .editorconfig's own directory, and a
  # leading `/` says so without adding a directory to match.
  ['Makefile', ['Makefile', 'src/Makefile', 'a/b/c/Makefile'], ['Makefile.in']],
  ['*.py', ['x.py', 'src/x.py', 'a/b/x.py'], ['x.pyc', 'py']],
  ['/top.c', ['top.c'], ['lib/top.c', 'a/b/top.c']],
  ['/lib/*.c', ['lib/x.c'], ['x.c', 'src/lib/x.c']],
  ['src/*.js', ['src/a.js'], ['a.js', 'src/a/b.js', 'x/src/a.js']],

  # `**` crosses separators, and `/**/` also stands for a single separator, so
  # lib/x.c is covered by lib/**/*.c.
  ['lib/**/*.c', ['lib/x.c', 'lib/deep/x.c', 'lib/deep/nested/x.c'],
    ['x.c', 'src/lib/x.c']],
  ['**/foo/*.c', ['foo/z.c', 'q/foo/z.c', 'a/b/foo/z.c'],
    ['foo/deep/z.c', 'z.c']],
  ['**.c', ['x.c', 'a/x.c', 'a/b/x.c'], ['x.h']],
  ['**/*', ['x.c', 'a/x.c', 'a/b/x.c'], []],
  ['dir/**', ['dir/f.c', 'dir/sub/f.c'], ['dir', 'other/f.c']],
  ['**/tests/**/*.rs', ['tests/unit/t.rs', 'a/tests/b/t.rs'], ['src/t.rs']],

  # `?` is one character and, like `*`, not a separator.
  ['?.c', ['a.c', 'lib/a.c'], ['ab.c', '.c']],
  ['a?c.txt', ['abc.txt'], ['ac.txt', 'abbc.txt']],
  ['?/*.c', ['a/b.c'], ['ab/c.c', 'b.c']],

  # Character classes.
  ['[abc].c', ['a.c', 'b.c', 'c.c'], ['d.c', 'ab.c']],
  ['[a-z].c', ['a.c', 'q.c', 'z.c'], ['1.c', 'A.c']],
  ['[!a-z].c', ['1.c', 'A.c', '].c'], ['a.c', 'q.c']],
  ['*.[ch]', ['x.c', 'x.h'], ['x.o', 'x.ch']],
  # A `]` is an ordinary member when it comes first, and `[[]` is the bracket.
  ['[]].c', ['].c'], ['a.c']],
  ['[[]].c', ['[].c'], ['[.c', '].c']],
  # An unterminated `[` is a literal bracket rather than a regex error.
  ['[abc.c', ['[abc.c'], ['a.c']],

  # Brace alternation, including an empty branch and nesting.
  ['*.{c,h}', ['x.c', 'x.h'], ['x.o', 'x.{c,h}']],
  ['{a,b}.c', ['a.c', 'b.c'], ['c.c', '{a,b}.c']],
  ['{a,{b,c}}.txt', ['a.txt', 'b.txt', 'c.txt'], ['d.txt']],
  ['{,x}.c', ['.c', 'x.c'], ['y.c']],
  ['{src,lib}/**/*.{c,h}', ['src/a.c', 'lib/deep/a.h'], ['doc/a.c', 'src/a.o']],
  # No comma, so the braces are part of the name — including when the group is
  # empty and when it holds a whole word.
  ['{}', ['{}'], ['x', '{a}']],
  ['{single}.c', ['{single}.c'], ['single.c']],
  ['{a,b/c}.txt', ['a.txt', 'b/c.txt'], ['b.txt', 'c.txt']],

  # Numeric ranges, negatives included.  A name spelled with a leading zero is
  # not the integer it would parse as, so `{1..100}` leaves 007 alone.
  ['f{1..10}.txt', ['f1.txt', 'f7.txt', 'f10.txt'],
    ['f0.txt', 'f11.txt', 'f07.txt']],
  ['n{1..100}.txt', ['n1.txt', 'n50.txt', 'n100.txt'],
    ['n0.txt', 'n200.txt', 'n007.txt']],
  # Deviation: the reference rejects the name `0` here, we accept it.
  ['x{-2..2}.c', ['x-2.c', 'x-1.c', 'x0.c', 'x2.c'],
    ['x-3.c', 'x3.c', 'x00.c']],
  # Vim has nine capture groups and a tenth `\(` is E872, thrown from inside a
  # BufReadPost.  A tenth range in one pattern therefore matches any integer
  # without its bounds being checked — j9 below is outside {1..3} and matches —
  # which is a wider answer than the spec asks for and not an error message.
  ['a{1..3}b{1..3}c{1..3}d{1..3}e{1..3}f{1..3}g{1..3}h{1..3}i{1..3}j{1..3}.txt',
    ['a1b1c1d1e1f1g1h1i1j1.txt', 'a1b1c1d1e1f1g1h1i1j9.txt'],
    ['a9b1c1d1e1f1g1h1i1j1.txt', 'a1b1c1d1e1f1g1h1i1.txt']],

  # Escapes.  Deviations: the reference matches every .c file for the first of
  # these, and raises an exception rather than answering for the second.
  ['\*.c', ['*.c'], ['a.c', 'lib/x.c']],
  ['\{a\}.c', ['{a}.c'], ['a.c']],
  ['a\,b.txt', ['a,b.txt'], ['a.txt', 'b.txt']],
  ['\?.c', ['?.c'], ['a.c']],

  # Names that look like patterns are still just names.
  ['*.c', ['a.c', '.c', '*.c', 'lib/deep/x.c'], ['a.h', 'a.c.bak']],
]

const BASE = tempname()
mkdir(BASE, 'p')

# One buffer per distinct path, reused for every pattern that asks about it: the
# matcher only ever sees the buffer's name, so there is nothing to gain from
# opening the same name twice.
var buffers: dict<number> = {}
def BufferFor(path: string): number
  if has_key(buffers, path)
    return buffers[path]
  endif
  var full = BASE .. '/' .. path
  mkdir(fnamemodify(full, ':h'), 'p')
  var buf = bufadd(full)
  bufload(buf)
  buffers[path] = buf
  return buf
enddef

def Matches(pattern: string, path: string): bool
  writefile(['root = true', '[' .. pattern .. ']', 'indent_size = 7'],
    BASE .. '/.editorconfig')
  var buf = BufferFor(path)
  simpleeditorconfig#Apply(buf)
  var applied = getbufvar(buf, 'simpleeditorconfig', {})
  return get(applied, 'indent_size', '') ==# '7'
enddef

for [pattern, matching, missing] in CASES
  for path in matching
    assert_true(Matches(pattern, path),
      printf('[%s] should match %s', pattern, path))
  endfor
  for path in missing
    assert_false(Matches(pattern, path),
      printf('[%s] should not match %s', pattern, path))
  endfor
endfor

# A collection Vim refuses to compile — `[z-a]` is E944 — used to be discovered
# on every buffer read, because that is where the regex was first run.  The
# section it came from is dropped with one warning and the rest of the file
# still applies.
writefile(['root = true', '[[z-a].c]', 'indent_size = 7',
  '[*]', 'indent_size = 2'], BASE .. '/.editorconfig')
var survivor = BufferFor('reverse_range.c')
silent! simpleeditorconfig#Apply(survivor)
assert_equal('2',
  get(getbufvar(survivor, 'simpleeditorconfig', {}), 'indent_size', ''),
  'an unusable section must not take the rest of the .editorconfig with it')

# The other way a section can be uncompilable, and it never reaches the regex
# engine at all: compiling recurses once per level of brace nesting, so about a
# hundred nested `{a,` groups is E132 rather than E944.  Same rule — the section
# is dropped, the file keeps working.  (The brace expansion this replaced did
# not get that far: twenty levels of nesting took it 3.4 s and twenty-five ran
# until interrupted.)
writefile(['root = true',
  '[' .. repeat('{a,', 200) .. 'z' .. repeat('}', 200) .. '.c]',
  'indent_size = 7', '[*]', 'indent_size = 2'], BASE .. '/.editorconfig')
var nested = BufferFor('deep_nesting.c')
silent! simpleeditorconfig#Apply(nested)
assert_equal('2',
  get(getbufvar(nested, 'simpleeditorconfig', {}), 'indent_size', ''),
  'a section too deeply nested to compile must not take the file down with it')

# 'ignorecase' and 'nomagic' are the user's business and neither may change what
# a section glob means.  matchlist(), which the numeric-range path uses, honours
# 'ignorecase'; and under 'nomagic' every `.` and `*` in a compiled glob would
# stop meaning what it was compiled to mean.  The regex carries `\m\C` for that
# reason, and these four cases are what would break without it.
set ignorecase nomagic
assert_true(Matches('*.c', 'x.c'))
assert_false(Matches('*.c', 'XX.C'))
assert_true(Matches('f{1..9}.txt', 'f2.txt'))
assert_false(Matches('f{1..9}.txt', 'FF2.TXT'))
set noignorecase magic

# Rewriting the same table of patterns through one .editorconfig, as the loop
# above just did, also proves the parsed-config cache cannot serve a stale file:
# every one of those writes lands in the same second as the read before it, and
# a cache keyed on getftime() alone would have answered the first pattern's
# question for all of them.  Two more writes make that explicit.
writefile(['root = true', '[*]', 'indent_size = 2'], BASE .. '/.editorconfig')
var probe = BufferFor('cache_probe.c')
simpleeditorconfig#Apply(probe)
assert_equal('2', getbufvar(probe, 'simpleeditorconfig').indent_size)
writefile(['root = true', '[*]', 'indent_size = 6'], BASE .. '/.editorconfig')
simpleeditorconfig#Apply(probe)
assert_equal('6', getbufvar(probe, 'simpleeditorconfig').indent_size,
  'a .editorconfig rewritten within the same second must not be served stale')

# And the other half of the invalidation: once the file's mtime is safely in the
# past the entry is cached, so a later write has to be noticed by its mtime
# changing rather than by the entry never being stored.
while getftime(BASE .. '/.editorconfig') == localtime()
  sleep 50m
endwhile
simpleeditorconfig#Apply(probe)
assert_equal('6', getbufvar(probe, 'simpleeditorconfig').indent_size)
writefile(['root = true', '[*]', 'indent_size = 3'], BASE .. '/.editorconfig')
simpleeditorconfig#Apply(probe)
assert_equal('3', getbufvar(probe, 'simpleeditorconfig').indent_size,
  'a .editorconfig written after its cache entry was stored must be re-read')

# The exponential is gone.  Twenty {a,b} groups is 2^20 patterns to the brace
# expansion this replaced: this very section, run against the old code, took
# 3.5 s per buffer opened — on every file in the project, for as long as the
# .editorconfig said so.  Compiled to one alternation it is under a tenth of a
# millisecond, so the budget below is loose enough for a busy machine and still
# seven times under what the enumeration measured.
const GROUPS = repeat('{a,b}', 20)
writefile(['root = true', '[' .. GROUPS .. '.c]', 'indent_size = 5'],
  BASE .. '/.editorconfig')
var wide = BufferFor(repeat('ab', 10) .. '.c')
var started = reltime()
simpleeditorconfig#Apply(wide)
var elapsed = reltimefloat(reltime(started)) * 1000
assert_equal('5', getbufvar(wide, 'simpleeditorconfig').indent_size,
  'twenty brace groups must still match')
assert_true(elapsed < 500,
  printf('twenty brace groups took %.1f ms, budget 500 ms', elapsed))

delete(BASE, 'rf')
if !empty(v:errors)
  writefile(v:errors, ROOT .. '/tests/errors.log')
  cquit
endif
qa!
