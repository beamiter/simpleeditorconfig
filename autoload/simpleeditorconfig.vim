vim9script

var s_generation = 0
var s_read_encoding_generation = 0
var s_read_encoding_stack: list<dict<any>> = []

def Warn(message: string)
  echohl WarningMsg
  echomsg '[SimpleEditorConfig] ' .. message
  echohl None
enddef

def Flag(name: string, fallback: bool): bool
  var configured: any = get(g:, name, fallback ? 1 : 0)
  if type(configured) == v:t_bool
    return configured
  endif
  return type(configured) == v:t_number ? configured != 0 : fallback
enddef

# EditorConfig values may be double-quoted, and a `#` or `;` starts an inline
# comment only when it is preceded by whitespace — `foo#bar` is a value, `foo
# bar` is `foo` plus a comment.  Quoted text keeps interior hashes and
# unescapes `\"` and `\\`.
def ParseValue(raw: string): string
  var text = trim(raw)
  if strpart(text, 0, 1) ==# '"'
    var out = ''
    var i = 1
    var last = strlen(text)
    while i < last
      var char = strpart(text, i, 1)
      if char ==# '\' && i + 1 < last
        var next = strpart(text, i + 1, 1)
        if next ==# '"' || next ==# '\'
          out ..= next
          i += 2
          continue
        endif
      endif
      if char ==# '"'
        return out
      endif
      out ..= char
      i += 1
    endwhile
    return out
  endif
  var cut = match(text, '\m\s\+[;#]')
  return cut < 0 ? text : strpart(text, 0, cut)
enddef

def Parse(lines: list<string>): dict<any>
  var result: dict<any> = {root: false, sections: []}
  var current: dict<any> = {}
  for raw in lines
    var line = trim(raw)
    if empty(line) || line =~# '\m^[#;]'
      continue
    endif
    if line =~# '\m^\[.*\]$'
      current = {
        pattern: strpart(line, 1, strlen(line) - 2),
        properties: {},
      }
      add(result.sections, current)
      continue
    endif
    # EditorConfig is INI-like, but its key/value delimiter is specifically the
    # first `=`.  Accepting `:` silently turned invalid lines into properties
    # and made a value containing a colon depend on what preceded it.
    var separator = match(line, '=')
    if separator < 0
      continue
    endif
    var key = tolower(trim(strpart(line, 0, separator)))
    var value = ParseValue(strpart(line, separator + 1))
    if empty(current)
      if key ==# 'root'
        result.root = tolower(value) ==# 'true'
      endif
    elseif !empty(key)
      current.properties[key] = value
    endif
  endfor
  return result
enddef

# An EditorConfig section glob is not a Vim glob, and glob2regpat() is not a
# stand-in for one.  It compiles `*` to `.*`, so `[lib/*.c]` claimed
# lib/deep/nested/x.c when the spec says `*` never crosses a separator; it hands
# `[!abc]` straight through as a Vim collection, which matches `!`, `a`, `b` and
# `c` — the exact inverse of the negation that was asked for; it turns
# `{1..9}` into a group matching the literal text `1..9`, so a numeric range
# matched nothing at all; it treats `a{b}c.txt` as a group even though a brace
# group with no comma in it is the literal file name; and it drops the leading
# `^` for any pattern starting with `*`, leaving the result unanchored.
#
# The brace cross-product that used to run first was worse than wrong, it was
# slow in a way a colleague could weaponise by accident: it enumerated every
# combination, so one section with N `{a,b}` groups cost 2^N candidate patterns.
# Measured on this code, N=14 took 59 ms per buffer opened, N=16 240 ms, N=18
# 1.0 s — on the BufReadPost path, for every file in the project.
#
# So a section glob is compiled here, once, into a single anchored Vim regex,
# with alternation where the old code had enumeration: N brace groups cost N
# alternations rather than 2^N patterns.

# The characters that are magic in a Vim pattern under the default 'magic'.
# `{` is deliberately absent: the quantifier is spelled `\{n,m\}`, so a bare
# brace is already the literal we want for a comma-less group.
const MAGIC = '\.*[]~^$'

# Compiled section globs keyed by the raw pattern.  Compiling is a pure function
# of the pattern and a project reuses the same handful of patterns for every
# buffer it opens, so this only ever grows by the number of distinct patterns a
# session has seen.
var s_globs: dict<dict<any>> = {}

# `[abc]`, `[!abc]` and `[a-z]` map onto a Vim collection almost directly, but
# EditorConfig spells negation `!` where Vim spells it `^`, and a `]` is an
# ordinary member when it comes first.  A `[` with no closing `]` is not a
# collection at all — it is a literal bracket, and emitting an unterminated Vim
# collection instead would throw a regex error in the middle of a BufReadPost.
# Returns the regex fragment and the index just past the collection.
def CompileClass(chars: list<string>, start: number): list<any>
  var last = len(chars)
  var i = start + 1
  var negated = i < last && (chars[i] ==# '!' || chars[i] ==# '^')
  if negated
    i += 1
  endif
  var members = ''
  if i < last && chars[i] ==# ']'
    members ..= '\]'
    i += 1
  endif
  while i < last && chars[i] !=# ']'
    if chars[i] ==# '\' && i + 1 < last
      # An escaped member is literal, including the `-` that would otherwise
      # open a range and the `]` that would otherwise close the collection.
      members ..= escape(chars[i + 1], '\]^-')
      i += 2
      continue
    endif
    members ..= chars[i] ==# '\' ? '\\' : chars[i]
    i += 1
  endwhile
  if i >= last
    return ['\[', start + 1]
  endif
  return ['[' .. (negated ? '^' : '') .. members .. ']', i + 1]
enddef

# The index of the `}` closing the group that opens at `start`, or -1 when the
# pattern never closes it.
def CloseBrace(chars: list<string>, start: number): number
  var last = len(chars)
  var depth = 0
  var i = start
  while i < last
    if chars[i] ==# '\'
      i += 2
      continue
    endif
    if chars[i] ==# '{'
      depth += 1
    elseif chars[i] ==# '}'
      depth -= 1
      if depth == 0
        return i
      endif
    endif
    i += 1
  endwhile
  return -1
enddef

# Split a group body on its top-level commas.  A single choice coming back means
# the body held no comma at this level, which is how `a{b}c.txt` is told apart
# from `a{b,c}.txt`: the first names a file, the second offers a choice.
def SplitChoices(body: list<string>): list<list<string>>
  var choices: list<list<string>> = []
  var current: list<string> = []
  var depth = 0
  var i = 0
  while i < len(body)
    var char = body[i]
    if char ==# '\' && i + 1 < len(body)
      extend(current, [char, body[i + 1]])
      i += 2
      continue
    endif
    if char ==# '{'
      depth += 1
    elseif char ==# '}'
      depth -= 1
    endif
    if char ==# ',' && depth == 0
      add(choices, current)
      current = []
    else
      add(current, char)
    endif
    i += 1
  endwhile
  add(choices, current)
  return choices
enddef

# A run of decimal digits in a Vim regex, with no capture group.  Numeric range
# globs cannot use one capture per range: Vim exposes only nine captures, so the
# tenth range used to accept every integer without checking its bounds.
def DigitRun(count: number): string
  return count <= 0 ? '' : count == 1 ? '\d' : '\d\{' .. count .. '}'
enddef

def Alternatives(parts: list<string>): string
  return empty(parts) ? '\%(\)\@!'
    : len(parts) == 1 ? parts[0] : '\%(' .. join(parts, '\|') .. '\)'
enddef

# Match two non-negative, equally wide decimal strings inclusively.  This is a
# compact decimal trie rather than an alternation of every number: {1..9999}
# stays a handful of branches instead of becoming 9999 of them.  Leading zeroes
# are possible here because this helper also compiles suffixes; UnsignedRange()
# chooses a non-zero first digit for multi-digit numbers.
def FixedDecimalRange(low: string, high: string): string
  var width = strlen(low)
  if low ==# high
    return low
  endif
  if low ==# repeat('0', width) && high ==# repeat('9', width)
    return DigitRun(width)
  endif

  var common = 0
  while common < width
      && strpart(low, common, 1) ==# strpart(high, common, 1)
    common += 1
  endwhile
  var prefix = strpart(low, 0, common)
  var low_digit = str2nr(strpart(low, common, 1))
  var high_digit = str2nr(strpart(high, common, 1))
  var rest = width - common - 1
  var pieces: list<string> = []

  var lower = string(low_digit)
  if rest > 0
    lower ..= FixedDecimalRange(strpart(low, common + 1), repeat('9', rest))
  endif
  add(pieces, lower)

  if low_digit + 1 <= high_digit - 1
    var middle_digit = low_digit + 1 == high_digit - 1
      ? string(low_digit + 1)
      : $'[{low_digit + 1}-{high_digit - 1}]'
    add(pieces, middle_digit .. DigitRun(rest))
  endif

  var upper = string(high_digit)
  if rest > 0
    upper ..= FixedDecimalRange(repeat('0', rest),
      strpart(high, common + 1))
  endif
  add(pieces, upper)
  return prefix .. Alternatives(pieces)
enddef

def UnsignedRange(low: number, high: number): string
  var parts: list<string> = []
  var width = strlen(string(low))
  var last_width = strlen(string(high))
  while width <= last_width
    var first = width == 1 ? 0 : str2nr('1' .. repeat('0', width - 1))
    var last = str2nr(repeat('9', width))
    var range_low = max([low, first])
    var range_high = min([high, last])
    if range_low <= range_high
      add(parts, FixedDecimalRange(string(range_low), string(range_high)))
    endif
    width += 1
  endwhile
  return Alternatives(parts)
enddef

# Compile a signed integer interval directly into a non-capturing regex.  The
# spellings accepted by the old numeric check are preserved: an optional `+`
# on non-negative numbers and -0 are accepted, but multi-digit leading zeroes
# are not.
def NumberRange(low: number, high: number): string
  if low > high
    return '\%(\)\@!'
  endif
  var parts: list<string> = []
  if low < 0
    var negative_high = min([high, -1])
    if low == v:numbermin
      # abs(v:numbermin) is one larger than v:numbermax and cannot itself be a
      # Vim Number.  Spell that single endpoint as text and compile the rest of
      # the magnitude interval normally.
      var magnitudes = negative_high == v:numbermin
        ? [strpart(string(v:numbermin), 1)]
        : [UnsignedRange(-negative_high, v:numbermax),
          strpart(string(v:numbermin), 1)]
      add(parts, '-' .. Alternatives(magnitudes))
    else
      add(parts, '-' .. UnsignedRange(-negative_high, -low))
    endif
  endif
  if low <= 0 && high >= 0
    add(parts, '[-+]\?0')
  endif
  if high > 0
    add(parts, '+\?' .. UnsignedRange(max([low, 1]), high))
  endif
  return Alternatives(parts)
enddef

# Compile one glob into a Vim regex fragment.  Works on a list of characters
# rather than the string so a multibyte pattern indexes the same way an ASCII
# one does.
def CompileGlob(chars: list<string>): string
  var out = ''
  var last = len(chars)
  var i = 0
  while i < last
    var char = chars[i]
    if char ==# '\'
      # A backslash escapes whatever follows it.  (The upstream Python
      # implementation honours this only before a comma or a brace, so it reads
      # `\*.c` as `*.c`; the spec, the Rust implementations and anyone who names
      # a file `*.c` all disagree with it.)
      out ..= i + 1 < last ? escape(chars[i + 1], MAGIC) : '\\'
      i += 2
    elseif char ==# '*'
      if i + 1 < last && chars[i + 1] ==# '*'
        out ..= '.*'
        i += 2
      else
        out ..= '[^/]*'
        i += 1
      endif
    elseif char ==# '?'
      out ..= '[^/]'
      i += 1
    elseif char ==# '/'
      # `/**/` stands for a single separator as well as for any run of
      # directories, which is what makes `lib/**/*.c` cover lib/x.c and not only
      # lib/deep/x.c.
      if i + 3 < last && chars[i + 1] ==# '*' && chars[i + 2] ==# '*'
          && chars[i + 3] ==# '/'
        out ..= '/\%(.*/\)\?'
        i += 4
      else
        out ..= '/'
        i += 1
      endif
    elseif char ==# '['
      var collection = CompileClass(chars, i)
      out ..= collection[0]
      i = collection[1]
    elseif char ==# '{'
      var close = CloseBrace(chars, i)
      if close < 0
        out ..= '{'
        i += 1
        continue
      endif
      var body = slice(chars, i + 1, close)
      var bounds = matchlist(join(body, ''),
        '^\([-+]\?\d\+\)\.\.\([-+]\?\d\+\)$')
      if !empty(bounds)
        out ..= NumberRange(str2nr(bounds[1]), str2nr(bounds[2]))
      else
        var choices = SplitChoices(body)
        if len(choices) == 1
          out ..= '{' .. CompileGlob(choices[0]) .. '}'
        else
          var alternatives: list<string> = []
          for choice in choices
            add(alternatives, CompileGlob(choice))
          endfor
          out ..= '\%(' .. join(alternatives, '\|') .. '\)'
        endif
      endif
      i = close + 1
    else
      out ..= escape(char, MAGIC)
      i += 1
    endif
  endwhile
  return out
enddef

def SectionGlob(pattern: string): dict<any>
  if has_key(s_globs, pattern)
    return s_globs[pattern]
  endif
  var glob = pattern
  # A pattern with no separator in it matches the name at any depth below the
  # .editorconfig; one with a separator is anchored to the .editorconfig's own
  # directory, and a leading `/` only says so more loudly.  The test is made
  # before the leading `/` is stripped, so `[/top.c]` stays anchored.
  var anchored = stridx(glob, '/') >= 0
  var prefix = '\%(.*/\)\?'
  if anchored
    glob = substitute(glob, '^/', '', '')
    # A leading `**/` also stands for no directory at all: `[**/foo/*.c]` covers
    # foo/z.c as well as q/foo/z.c.
    prefix = ''
    if strpart(glob, 0, 3) ==# '**/'
      prefix = '\%(.*/\)\?'
      glob = strpart(glob, 3)
    endif
  endif
  var compiled: dict<any> = {regex: '', usable: true}
  # Both halves of this are fallible and they fail for the same reason, so they
  # share one guard.  Not every collection a user can type is a collection Vim
  # will run: `[z-a]` is E944, and Vim only finds that out when the regex is
  # first used.  And not every pattern can be compiled at all: CompileGlob()
  # recurses once per level of brace nesting, so a section with about a hundred
  # nested `{a,` groups is E132 before any regex exists.  Either one, left
  # alone, is thrown inside a BufReadPost for every file opened in the project,
  # forever.  Take them here instead, once, and let the unusable section match
  # nothing rather than take the rest of the .editorconfig down with it.
  #
  # `\m\C` pins the regex to magic and case-sensitive matching whatever the user
  # has set 'magic' and 'ignorecase' to: matchlist() below honours 'ignorecase',
  # and a file name is not a search.
  try
    compiled.regex = '\m\C^' .. prefix
      .. CompileGlob(split(glob, '\zs')) .. '$'
    var probe = 'x' =~# compiled.regex
  catch
    Warn(printf('ignoring section [%s]: %s', pattern,
      substitute(v:exception, '^Vim(\a*):', '', '')))
    compiled.usable = false
  endtry
  s_globs[pattern] = compiled
  return compiled
enddef

def SectionMatches(pattern: string, config_dir: string, path: string): bool
  var relative = path ==# config_dir ? fnamemodify(path, ':t')
    : substitute(strpart(path, strlen(config_dir)), '^/', '', '')
  var compiled = SectionGlob(pattern)
  if !compiled.usable
    return false
  endif
  return relative =~# compiled.regex
enddef

def Effective(configs: list<dict<any>>, path: string): dict<string>
  var properties: dict<string> = {}
  for config in configs
    for section in config.parsed.sections
      if !SectionMatches(section.pattern, config.dir, path)
        continue
      endif
      for [key, value] in items(section.properties)
        if tolower(value) ==# 'unset'
          # `unset` takes back a value an earlier section gave, and a section is
          # perfectly entitled to unset something nothing ever set — a child
          # .editorconfig that clears a key its parent happens not to define.
          # remove() on an absent key is E716, thrown out of Apply() on the
          # BufReadPost path, which loses every other property of the file as
          # well as the one being unset.
          if has_key(properties, key)
            remove(properties, key)
          endif
        else
          properties[key] = value
        endif
      endfor
    endfor
  endfor
  return properties
enddef

def BufferBaseline(buf: number): dict<any>
  var existing = getbufvar(buf, 'simpleeditorconfig_baseline', {})
  if type(existing) == v:t_dict && !empty(existing)
    setbufvar(buf, 'simpleeditorconfig_pre_read_fileencoding', v:null)
    return existing
  endif
  var pre_read_fileencoding: any = getbufvar(buf,
    'simpleeditorconfig_pre_read_fileencoding', v:null)
  var baseline = {
    expandtab: getbufvar(buf, '&expandtab'),
    shiftwidth: getbufvar(buf, '&shiftwidth'),
    softtabstop: getbufvar(buf, '&softtabstop'),
    tabstop: getbufvar(buf, '&tabstop'),
    fileformat: getbufvar(buf, '&fileformat'),
    # BeforeRead may have forced decoding through global 'fileencodings'.  The
    # resulting local value belongs to EditorConfig, not to the editor state
    # RestoreBaseline must recover if `charset` is later removed.
    fileencoding: type(pre_read_fileencoding) == v:t_string
      ? pre_read_fileencoding : getbufvar(buf, '&fileencoding'),
    bomb: getbufvar(buf, '&bomb'),
    textwidth: getbufvar(buf, '&textwidth'),
    fixendofline: getbufvar(buf, '&fixendofline'),
    endofline: getbufvar(buf, '&endofline'),
  }
  setbufvar(buf, 'simpleeditorconfig_baseline', baseline)
  setbufvar(buf, 'simpleeditorconfig_pre_read_fileencoding', v:null)
  return baseline
enddef

def SetOption(buf: number, name: string, value: any)
  setbufvar(buf, '&' .. name, value)
enddef

def RestoreBaseline(buf: number)
  for [name, value] in items(BufferBaseline(buf))
    SetOption(buf, name, value)
  endfor
enddef

def Positive(value: string): number
  return value =~# '^\d\+$' && str2nr(value) > 0 ? str2nr(value) : 0
enddef

def CharsetEncoding(charset: string): string
  return get({
    'utf-8': 'utf-8',
    'utf-8-bom': 'utf-8',
    latin1: 'latin1',
    # Vim's ucs-2 encodings cannot represent surrogate pairs.  Its utf-16
    # names are the corresponding big- and little-endian encodings and retain
    # non-BMP characters on both read and write.
    'utf-16be': 'utf-16',
    'utf-16le': 'utf-16le',
  }, tolower(charset), '')
enddef

def ApplyProperties(buf: number, properties: dict<string>, sources: list<string>)
  if !bufexists(buf)
    return
  endif
  RestoreBaseline(buf)
  var configured_tab_width = Positive(get(properties, 'tab_width', ''))
  var indent_value = tolower(get(properties, 'indent_size', ''))
  var indent_size = indent_value ==# 'tab'
    ? (configured_tab_width > 0
      ? configured_tab_width : getbufvar(buf, '&tabstop'))
    : Positive(indent_value)
  # Per EditorConfig, tab_width defaults to a numeric indent_size regardless
  # of indent_style.  Previously that inheritance happened only for spaces,
  # leaving `indent_style = tab, indent_size = 4` at the editor's old tabstop.
  var tab_width = configured_tab_width > 0
    ? configured_tab_width : indent_size
  var indent_style = tolower(get(properties, 'indent_style', ''))
  if indent_style ==# 'space'
    SetOption(buf, 'expandtab', 1)
  elseif indent_style ==# 'tab'
    SetOption(buf, 'expandtab', 0)
  endif
  if tab_width > 0
    SetOption(buf, 'tabstop', tab_width)
  endif
  if indent_size > 0
    SetOption(buf, 'shiftwidth', indent_size)
    SetOption(buf, 'softtabstop', indent_size)
  endif
  var endings = {lf: 'unix', crlf: 'dos', cr: 'mac'}
  var ending = tolower(get(properties, 'end_of_line', ''))
  if has_key(endings, ending)
    SetOption(buf, 'fileformat', endings[ending])
  endif
  var charset = tolower(get(properties, 'charset', ''))
  var encoding = CharsetEncoding(charset)
  if !empty(encoding)
    SetOption(buf, 'fileencoding', encoding)
    # 'bomb' is independent of trailing-whitespace cleanup.  Keeping it as a
    # deferred flag in BeforeWrite() meant `charset = utf-8-bom` did nothing
    # unless the same section also enabled trim_trailing_whitespace.  Set the
    # buffer option with the rest of the charset now; RestoreBaseline() above
    # also clears a BOM when a reload removes or changes the property.
    SetOption(buf, 'bomb', charset ==# 'utf-8-bom' ? 1 : 0)
  endif
  setbufvar(buf, 'simpleeditorconfig_bomb', !!getbufvar(buf, '&bomb'))
  var maximum = tolower(get(properties, 'max_line_length', ''))
  if maximum ==# 'off'
    SetOption(buf, 'textwidth', 0)
  elseif Positive(maximum) > 0
    SetOption(buf, 'textwidth', Positive(maximum))
  endif
  var final_newline = tolower(get(properties, 'insert_final_newline', ''))
  if final_newline ==# 'true'
    SetOption(buf, 'fixendofline', 1)
    SetOption(buf, 'endofline', 1)
  elseif final_newline ==# 'false'
    # 'fixendofline' only stops Vim from repairing a missing newline.  'eol'
    # records whether this buffer is meant to have one at all and must be
    # cleared as well to ensure the next write removes an existing terminator.
    SetOption(buf, 'fixendofline', 0)
    SetOption(buf, 'endofline', 0)
  endif
  setbufvar(buf, 'simpleeditorconfig', properties)
  setbufvar(buf, 'simpleeditorconfig_sources', sources)
  setbufvar(buf, 'simpleeditorconfig_trim',
    tolower(get(properties, 'trim_trailing_whitespace', '')) ==# 'true')
  if Flag('simpleeditorconfig_verbose', false)
    echomsg printf('[SimpleEditorConfig] %s: %d properties from %d file(s)',
      bufname(buf), len(properties), len(sources))
  endif
enddef

# 'fileencoding' is assigned only after Vim has decoded a file, so changing it
# on BufReadPost controls the next write but cannot repair text already read as
# bytes.  The encoding candidates in 'fileencodings' are consulted after
# BufReadPre, however.  Temporarily narrow that global list to the charset the
# applicable .editorconfig declares, then restore the exact user value as soon
# as the read completes.  Reads are synchronous; the per-buffer saved value
# also forms a stack if another buffer is opened by a BufReadPre autocmd.
def ClearReadEncodingBufferState(entry: dict<any>)
  var buf = get(entry, 'buf', -1)
  if bufexists(buf)
      && getbufvar(buf, 'simpleeditorconfig_read_encoding_token', -1)
        == get(entry, 'token', -2)
    setbufvar(buf, 'simpleeditorconfig_saved_fileencodings', v:null)
    setbufvar(buf, 'simpleeditorconfig_read_encoding_token', -1)
  endif
enddef

def DrainReadEncodingStack()
  while !empty(s_read_encoding_stack)
      && !!get(s_read_encoding_stack[-1], 'restore_requested', false)
    var entry = remove(s_read_encoding_stack, -1)
    var timer = get(entry, 'timer', 0)
    if timer > 0
      timer_stop(timer)
    endif
    var saved: any = get(entry, 'saved', v:null)
    if type(saved) == v:t_string
      &g:fileencodings = saved
    endif
    ClearReadEncodingBufferState(entry)
  endwhile
enddef

def RequestReadEncodingRestore(buf: number, token: number = -1)
  var idx = len(s_read_encoding_stack) - 1
  while idx >= 0
    var entry = s_read_encoding_stack[idx]
    if get(entry, 'buf', -1) == buf
        && (token < 0 || get(entry, 'token', -2) == token)
      entry.restore_requested = true
      DrainReadEncodingStack()
      return
    endif
    idx -= 1
  endwhile
enddef

def ReadEncodingFallback(token: number, timer: number)
  var idx = len(s_read_encoding_stack) - 1
  while idx >= 0
    var entry = s_read_encoding_stack[idx]
    if get(entry, 'token', -1) == token
        && get(entry, 'timer', -2) == timer
      entry.timer = 0
      entry.restore_requested = true
      DrainReadEncodingStack()
      return
    endif
    idx -= 1
  endwhile
enddef

export def BeforeRead(buf: number = bufnr())
  RestoreReadEncoding(buf)
  if !bufexists(buf) || !Flag('simpleeditorconfig_enable', true)
      || getbufvar(buf, '&buftype') !=# ''
    return
  endif
  var name = bufname(buf)
  if empty(name) || name =~# '^\a[[:alnum:]+.-]*://'
    return
  endif
  var path = resolve(fnamemodify(name, ':p'))
  var configs = LocalConfigs(path, ProjectionRoot(path))
  var charset = get(Effective(configs, path), 'charset', '')
  var encoding = CharsetEncoding(charset)
  if empty(encoding)
    return
  endif
  var baseline: any = getbufvar(buf, 'simpleeditorconfig_baseline', {})
  var pre_read: any = getbufvar(buf,
    'simpleeditorconfig_pre_read_fileencoding', v:null)
  if (type(baseline) != v:t_dict || empty(baseline))
      && type(pre_read) != v:t_string
    setbufvar(buf, 'simpleeditorconfig_pre_read_fileencoding',
      getbufvar(buf, '&fileencoding'))
  endif
  s_read_encoding_generation += 1
  if s_read_encoding_generation <= 0
    s_read_encoding_generation = 1
  endif
  var entry: dict<any> = {
    buf: buf,
    token: s_read_encoding_generation,
    saved: &g:fileencodings,
    timer: 0,
    restore_requested: false,
  }
  add(s_read_encoding_stack, entry)
  setbufvar(buf, 'simpleeditorconfig_saved_fileencodings', entry.saved)
  setbufvar(buf, 'simpleeditorconfig_read_encoding_token', entry.token)
  &g:fileencodings = encoding
  entry.timer = timer_start(0,
    function(ReadEncodingFallback, [entry.token]))
enddef

export def RestoreReadEncoding(buf: number = bufnr())
  var token: any = getbufvar(buf, 'simpleeditorconfig_read_encoding_token', -1)
  RequestReadEncodingRestore(buf, type(token) == v:t_number ? token : -1)
enddef

export def AfterRead(buf: number = bufnr())
  RestoreReadEncoding(buf)
  Apply(buf)
enddef

# Parsed .editorconfig files keyed by their full path.  Every file opened in a
# project re-walks the same directories and re-reads the same .editorconfig that
# the file before it read; with matching down to one compiled regex, reading and
# parsing is what is left on the BufReadPost path.
#
# A stale .editorconfig is worse than reading one again, so an entry is reused
# only when the file's mtime and size are still exactly what they were when it
# was read — and it is not stored at all until that mtime is safely in the
# past.  getftime() has one-second resolution, so a write landing in the same
# second as our read would otherwise be invisible for as long as the session
# lives, which is exactly the sequence "edit .editorconfig, save, open a file
# to see what it did".  "Safely" is two seconds rather than one because the
# clock a filesystem stamps files with and the one localtime() reads do not
# tick over at the same instant: on the same host they are known to disagree
# by a few milliseconds around a second boundary, and a stamp that is a second
# ahead of localtime() is what turned "not the current second" into a stale
# entry that lived for the rest of the session.  Once the margin has passed,
# ordinary later writes produce a different mtime, and the entry falls out
# on its own. Tools that preserve timestamps require an explicit Reload().
var s_parsed: dict<dict<any>> = {}

def ParseFile(file: string): dict<any>
  var ftime = getftime(file)
  var size = getfsize(file)
  var cached = get(s_parsed, file, {})
  if !empty(cached) && cached.ftime == ftime && cached.size == size
    return cached.parsed
  endif
  var parsed = Parse(readfile(file))
  if localtime() - ftime >= 2
    s_parsed[file] = {ftime: ftime, size: size, parsed: parsed}
  endif
  return parsed
enddef

# Walk from the file's directory towards the filesystem root, or towards
# `stop` when one is given: an sshfs workspace is a mount SimpleRemote made of
# the remote root, and what sits above the mount point —
# ~/.local/state/vim/simpleremote, ~/.editorconfig — belongs to this machine,
# not to the project.  Reading it would give a remote file properties its own
# repository never asked for.
def LocalConfigs(path: string, stop: string = ''): list<dict<any>>
  var configs: list<dict<any>> = []
  var dir = fnamemodify(path, ':h')
  while !empty(dir)
    var file = dir .. '/.editorconfig'
    if filereadable(file)
      var parsed = ParseFile(file)
      add(configs, {dir: dir, path: file, parsed: parsed})
      if parsed.root
        break
      endif
    endif
    if dir ==# stop
      break
    endif
    var parent = fnamemodify(dir, ':h')
    if parent ==# dir
      break
    endif
    dir = parent
  endwhile
  return reverse(configs)
enddef

# `path` is `root` itself or sits below it.  Plain string containment would
# call /workspace2/x a child of /workspace, which it is not.
def UnderRoot(path: string, root: string): bool
  if empty(root)
    return false
  endif
  var prefix = root ==# '/' ? '/' : root .. '/'
  return path ==# root || stridx(path, prefix) == 0
enddef

# The workspace's local projection, normalized, whatever the mode, or ''.
def LocalRoot(workspace: dict<any>): string
  var local_root = get(workspace, 'local_root', '')
  if type(local_root) != v:t_string || empty(local_root)
    return ''
  endif
  local_root = substitute(resolve(fnamemodify(local_root, ':p')), '/\+$', '', '')
  return empty(local_root) ? '/' : local_root
enddef

# The directory the walk must stop at for `path`, or ''.
#
# Only an sshfs mount qualifies.  It is a directory SimpleRemote itself made
# under ~/.local/state/vim/simpleremote/mounts to hang the remote root off,
# and the .editorconfig files above it are this machine's, addressed to
# nothing in particular.  ('mounting' is that mount being made and carries no
# local_root at all.)
#
# The other two projections are not that: local-map is a directory the user
# pointed the workspace at, and docker-bind resolves to the host side of a
# bind mount — either the user's own g:simpleremote_local_roots entry or the
# Source of the container's mount, which is a checkout sitting in the user's
# own tree.  Both are places the user chose on this machine, and a checkout
# inherits its surroundings like any local file; cutting the walk there would
# change what an ordinary local buffer gets the moment a workspace happens to
# be connected.
def ProjectionRoot(path: string): string
  var workspace = get(g:, 'simpleremote_workspace', {})
  if type(workspace) != v:t_dict
    return ''
  endif
  var mode = get(workspace, 'mode', '')
  if type(mode) != v:t_string || mode !=# 'sshfs'
    return ''
  endif
  var local_root = LocalRoot(workspace)
  return UnderRoot(path, local_root) ? local_root : ''
enddef

# Cache and in-flight reads share the same workspace/path identity. Keep the
# identity fields in values so a rename or a path containing ':' cannot make
# invalidation target another workspace.
var s_remote_parsed: dict<dict<any>> = {}
var s_remote_pending: dict<dict<any>> = {}
var s_remote_epoch = 0

def Workspace(): dict<any>
  var ws: any = get(g:, 'simpleremote_workspace', {})
  return type(ws) == v:t_dict ? ws : {}
enddef

def WorkspaceKey(ws: dict<any>): string
  var id: any = get(ws, 'id', -1)
  return type(id) == v:t_number && id >= 0
    ? string([id, get(ws, 'kind', ''), get(ws, 'target', ''), get(ws, 'root', '')]) : ''
enddef

def RemoteKey(scope: string, file: string): string
  return string([scope, file])
enddef

def RemoteFile(dir: string): string
  return (dir ==# '/' ? '' : dir) .. '/.editorconfig'
enddef

def RemoteBufferMatches(buf: number, path: string, ws: dict<any>): bool
  if !bufloaded(buf)
    return false
  endif
  var buftype = getbufvar(buf, '&buftype')
  var remote: any = getbufvar(buf, 'vimrc_remote', {})
  # SimpleRemote publishes an actual connection generation. Accept the
  # metadata-less legacy binding only for that already identified workspace.
  if (buftype !=# '' && buftype !=# 'acwrite') || type(remote) != v:t_dict
    return false
  endif
  var remote_path: any = get(remote, 'path', '')
  var generation: any = get(remote, 'generation', get(ws, 'id', -1))
  return type(remote_path) == v:t_string && remote_path ==# path
    && type(generation) == v:t_number && generation == get(ws, 'id', -1)
enddef

# Workspace changes, disconnect and explicit reload retire all old work.
# Outstanding transport callbacks are not cancelled globally; their identity
# is no longer present, so they cannot publish to any buffer or cache.
export def ForgetRemote()
  s_remote_parsed = {}
  s_remote_pending = {}
  s_remote_epoch += 1
enddef

def TouchesRemoteFile(path: string, file: string): bool
  if path =~# '\m/\.editorconfig$'
    return path ==# file
  endif
  # Any other event path may be a directory. An ordinary file is not an
  # ancestor of a candidate config, so it costs no reads or application.
  return UnderRoot(file, path)
enddef

def AffectedRemoteFile(paths: list<string>, file: string): bool
  for path in paths
    if TouchesRemoteFile(path, file)
      return true
    endif
  endfor
  return false
enddef

def RefreshRemotePaths(paths: list<string>, ws: dict<any>)
  var scope = WorkspaceKey(ws)
  if empty(scope) || empty(paths)
    return
  endif
  for key in keys(s_remote_parsed)
    var entry = s_remote_parsed[key]
    if entry.scope ==# scope && AffectedRemoteFile(paths, entry.file)
      remove(s_remote_parsed, key)
    endif
  endfor
  for key in keys(s_remote_pending)
    var request = s_remote_pending[key]
    if request.scope ==# scope && AffectedRemoteFile(paths, request.file)
      # Remove before starting its successor. A later reply for this exact
      # key can only reach listeners registered with that successor object.
      remove(s_remote_pending, key)
    endif
  endfor
  if !Flag('simpleeditorconfig_enable', true) || !Flag('simpleeditorconfig_remote', true)
    return
  endif
  var epoch = s_remote_epoch
  for info in getbufinfo({bufloaded: 1})
    var bound: any = getbufvar(info.bufnr, 'simpleeditorconfig_remote_binding', {})
    if type(bound) != v:t_dict || get(bound, 'scope', '') !=# scope
        || type(get(bound, 'path', 0)) != v:t_string
        || type(get(bound, 'files', 0)) != v:t_list
        || !RemoteBufferMatches(info.bufnr, bound.path, ws)
      continue
    endif
    for file in bound.files
      if !AffectedRemoteFile(paths, file)
        continue
      endif
      if epoch != s_remote_epoch || WorkspaceKey(Workspace()) !=# scope
        return
      endif
      Apply(info.bufnr)
      break
    endfor
  endfor
enddef

# The directories whose .editorconfig may apply to `path`: its own, then each
# parent, up to and including the workspace root — never above it, that is
# not the project.
def RemoteDirs(path: string, root: string): list<string>
  var dirs: list<string> = []
  var dir = fnamemodify(path, ':h')
  if !UnderRoot(dir, root)
    return dirs
  endif
  while true
    add(dirs, dir)
    if dir ==# root
      break
    endif
    var parent = fnamemodify(dir, ':h')
    if parent ==# dir || strlen(parent) < strlen(root)
      break
    endif
    dir = parent
  endwhile
  return dirs
enddef

def CanFinishRemote(state: dict<any>): bool
  if !Flag('simpleeditorconfig_enable', true) || !Flag('simpleeditorconfig_remote', true)
      || state.epoch != s_remote_epoch
      || getbufvar(state.buf, 'simpleeditorconfig_token', -1) != state.token
    return false
  endif
  var ws = Workspace()
  return WorkspaceKey(ws) ==# state.scope && RemoteBufferMatches(state.buf, state.path, ws)
enddef

# Wait for the bounded ancestor walk; a failure above the first root=true is
# irrelevant, while a failure at/below it leaves settings untouched. Record
# missing files as dependencies too: creation can change the effective rules.
def MaybeFinish(state: dict<any>)
  if state.done || state.answered < len(state.files)
    return
  endif
  state.done = true
  if !CanFinishRemote(state)
    return
  endif
  var configs: list<dict<any>> = []
  var files: list<string> = []
  for idx in range(len(state.files))
    var entry = state.results[idx]
    add(files, state.files[idx])
    if get(entry, 'failed', false)
      return
    endif
    if !entry.ok
      continue
    endif
    add(configs, {dir: state.dirs[idx], path: state.files[idx], parsed: entry.parsed})
    if entry.parsed.root
      break
    endif
  endfor
  setbufvar(state.buf, 'simpleeditorconfig_remote_binding',
    {scope: state.scope, path: state.path, files: files})
  var ordered = reverse(configs)
  ApplyProperties(state.buf, Effective(ordered, state.path),
    mapnew(ordered, (_, config) => config.path))
enddef

def Receive(state: dict<any>, idx: number, entry: dict<any>)
  if state.done
    return
  endif
  state.results[idx] = entry
  state.answered += 1
  MaybeFinish(state)
enddef

def OnSharedRead(key: string, request: dict<any>, ok: bool, body: string)
  if get(s_remote_pending, key, {}) isnot request
    return
  endif
  remove(s_remote_pending, key)
  if WorkspaceKey(Workspace()) !=# request.scope
    return
  endif
  # The agent's missing-file answer is cacheable. Transport errors are not.
  var failed = !ok && body !~# '\m^not a file:'
  var entry = {ok: ok, failed: failed, parsed: ok ? Parse(split(body, "\n", 1)) : {},
    scope: request.scope, file: request.file}
  if !failed
    s_remote_parsed[key] = entry
  endif
  for Deliver in values(request.listeners)
    call(Deliver, [entry])
  endfor
enddef

# A named function keeps each callback bound to its own directory index. The
# request must be visible before ReadFile, whose callback can run synchronously.
def IssueRead(state: dict<any>, idx: number): bool
  var file = state.files[idx]
  var key = RemoteKey(state.scope, file)
  var request = get(s_remote_pending, key, {})
  var Deliver = (entry) => Receive(state, idx, entry)
  var listener_key = string(state.buf)
  if !empty(request)
    request.listeners[listener_key] = Deliver
    return true
  endif
  request = {scope: state.scope, file: file, listeners: {[listener_key]: Deliver}}
  s_remote_pending[key] = request
  var sent = g:SimpleRemoteReadFile(file, (ok, body) =>
    OnSharedRead(key, request, !!ok, type(body) == v:t_string ? body : string(body)))
  if sent < 0
    # A refusing transport normally calls back immediately. Treat a refusal
    # without a callback as failure too, so it cannot leave an immortal key.
    OnSharedRead(key, request, false, 'remote workspace refused the request')
    return false
  endif
  return true
enddef

# Cache hits and pending requests are shared per path, not per whole walk.
# A change to one config can join still-valid parent/child reads in progress.
def Collect(buf: number, path: string, dirs: list<string>, scope: string, token: number)
  var files = mapnew(dirs, (_, dir) => RemoteFile(dir))
  var active_dirs = dirs
  # A still-fresh cached root is sufficient to exclude higher directories,
  # including from the reads issued after a lower file changes.
  for idx in range(len(files))
    var known = get(s_remote_parsed, RemoteKey(scope, files[idx]), {})
    if !empty(known) && known.ok && known.parsed.root
      files = files[: idx]
      active_dirs = dirs[: idx]
      break
    endif
  endfor
  var state: dict<any> = {buf: buf, path: path, dirs: active_dirs, files: files, token: token,
    scope: scope, results: repeat([{}], len(files)), answered: 0,
    done: false, epoch: s_remote_epoch}
  setbufvar(buf, 'simpleeditorconfig_remote_binding',
    {scope: scope, path: path, files: files})
  for idx in range(len(files))
    var cached = get(s_remote_parsed, RemoteKey(scope, files[idx]), {})
    if !empty(cached)
      state.results[idx] = cached
      state.answered += 1
    endif
  endfor
  for idx in range(len(files))
    if !empty(state.results[idx])
      continue
    endif
    if !IssueRead(state, idx) || state.done
      state.done = true
      return
    endif
  endfor
  MaybeFinish(state)
enddef

def ApplyRemote(buf: number, path: string, token: number)
  if !Flag('simpleeditorconfig_remote', true)
      || !exists('*g:SimpleRemoteReadFile')
    return
  endif
  var workspace = Workspace()
  var scope = WorkspaceKey(workspace)
  if empty(scope) || !RemoteBufferMatches(buf, path, workspace)
    return
  endif
  var configured_root: any = get(workspace, 'root', '')
  var root = type(configured_root) == v:t_string
    ? substitute(configured_root, '\m/\+$', '', '') : ''
  if root ==# ''
    root = '/'
  endif
  if !UnderRoot(path, root)
    return
  endif
  Collect(buf, path, RemoteDirs(path, root), scope, token)
enddef

export def Apply(buf: number = bufnr())
  if !bufexists(buf)
    return
  endif
  # Every Apply() supersedes remote work for this buffer, including a local or
  # disabled apply.  Previously only ApplyRemote() issued a token, so a buffer
  # repurposed while reads were in flight could receive its correct local
  # settings and then be overwritten by the older remote reply.
  # A buffer-local token survives :source of this autoload script.  Seed the
  # fresh script instance from it so a late closure created by the old instance
  # can never share the new request's generation.
  var previous = getbufvar(buf, 'simpleeditorconfig_token', 0)
  if type(previous) == v:t_number && previous > s_generation
    s_generation = previous
  endif
  s_generation += 1
  var token = s_generation
  setbufvar(buf, 'simpleeditorconfig_token', token)
  setbufvar(buf, 'simpleeditorconfig_remote_binding', {})
  var buftype = getbufvar(buf, '&buftype')
  if !Flag('simpleeditorconfig_enable', true)
      || (buftype !=# '' && buftype !=# 'acwrite')
    return
  endif
  var remote = getbufvar(buf, 'vimrc_remote', {})
  var remote_path: any = type(remote) == v:t_dict ? get(remote, 'path', '') : ''
  if type(remote_path) == v:t_string && !empty(remote_path)
    ApplyRemote(buf, remote_path, token)
    return
  endif
  var name = bufname(buf)
  if empty(name)
    return
  endif
  # BufReadPre already skips URI names so a failed SimpleRemote handshake
  # cannot be answered from this machine's ~/.editorconfig.  Apply() used to
  # walk fnamemodify(name, ':p') for `remote://...` buffers that had no
  # b:vimrc_remote dict yet, treating the URI as a local relative path.
  if name =~# '^\a[[:alnum:]+.-]*://'
    return
  endif
  var path = resolve(fnamemodify(name, ':p'))
  var configs = LocalConfigs(path, ProjectionRoot(path))
  ApplyProperties(buf, Effective(configs, path),
    mapnew(configs, (_, config) => config.path))
enddef

# :SimpleEditorConfigReload — the user asking for a fresh read, so the cached
# local and remote answers are dropped first. Metadata checks cannot detect
# same-sized replacements made by tools that preserve file timestamps.
export def Reload(buf: number = bufnr())
  s_parsed = {}
  ForgetRemote()
  Apply(buf)
enddef

export def ApplyRemoteEvent()
  var event: any = get(g:, 'simpleremote_event', {})
  if type(event) != v:t_dict || get(event, 'type', '') !=# 'buffer-read'
    return
  endif
  var announced: any = get(event, 'workspace', {})
  if type(announced) != v:t_dict || WorkspaceKey(announced) !=# WorkspaceKey(Workspace())
    return
  endif
  var buf: any = get(event, 'bufnr', -1)
  if type(buf) == v:t_number && buf > 0
    Apply(buf)
  endif
enddef

# Only changes from the currently active connection can retarget a walk;
# compare producer identity rather than interpreting a same-named path alone.
export def OnRemoteFilesChanged()
  var event: any = get(g:, 'simpleremote_event', {})
  if type(event) != v:t_dict
    return
  endif
  var ws = Workspace()
  var announced: any = get(event, 'workspace', {})
  var changes: any = get(event, 'changes', [])
  if type(announced) != v:t_dict || WorkspaceKey(announced) !=# WorkspaceKey(ws)
      || type(changes) != v:t_list
    return
  endif
  var paths: list<string> = []
  for change in changes
    if type(change) != v:t_dict
      continue
    endif
    var path: any = get(change, 'path', '')
    if type(path) == v:t_string && stridx(path, '/') == 0
      var normalized = substitute(path, '\m/\+$', '', '')
      add(paths, empty(normalized) ? '/' : normalized)
    endif
  endfor
  RefreshRemotePaths(paths, ws)
enddef

# BufWritePost: associate the saved config with the actual buffer connection,
# then invalidate only that path and re-apply to its affected loaded files.
export def AfterWrite()
  var remote: any = get(b:, 'vimrc_remote', {})
  var path: any = type(remote) == v:t_dict ? get(remote, 'path', '') : ''
  var ws = Workspace()
  if type(path) == v:t_string && stridx(path, '/') == 0
      && path ==# RemoteFile(fnamemodify(path, ':h'))
      && RemoteBufferMatches(bufnr(), path, ws)
    RefreshRemotePaths([path], ws)
  endif
enddef

export def BeforeWrite()
  if !Flag('simpleeditorconfig_enable', true)
      || !get(b:, 'simpleeditorconfig_trim', false) || !&l:modifiable || &l:readonly
    return
  endif
  var view = winsaveview()
  try
    silent! keepjumps keeppatterns :%substitute/\s\+$//e
  finally
    winrestview(view)
  endtry
enddef

# How the current buffer relates to the SimpleRemote workspace, for Info().
def WorkspaceLine(): string
  var workspace = get(g:, 'simpleremote_workspace', {})
  if type(workspace) != v:t_dict || empty(workspace)
    return ''
  endif
  var label = exists('*g:SimpleRemoteStatusline') ? g:SimpleRemoteStatusline() : ''
  if empty(label)
    label = get(workspace, 'kind', '') .. ':' .. get(workspace, 'target', '')
  endif
  var remote = get(b:, 'vimrc_remote', {})
  var relation = 'local'
  if type(remote) == v:t_dict && !empty(get(remote, 'path', ''))
    relation = 'remote'
  elseif &buftype ==# '' && !empty(bufname())
      && UnderRoot(resolve(fnamemodify(bufname(), ':p')), LocalRoot(workspace))
    # Any projection, not only the ones the walk stops at: this reports where
    # the buffer is, and Info() lists the sources it got right underneath.
    relation = 'projected'
  endif
  return printf('%s mode=%s buffer=%s', label,
    get(workspace, 'mode', 'virtual'), relation)
enddef

export def Info()
  var properties = get(b:, 'simpleeditorconfig', {})
  echomsg $'SimpleEditorConfig: {bufname()}'
  var workspace = WorkspaceLine()
  if !empty(workspace)
    echomsg '  workspace: ' .. workspace
  endif
  for source in get(b:, 'simpleeditorconfig_sources', [])
    echomsg '  source: ' .. source
  endfor
  for key in sort(keys(properties))
    echomsg $'  {key} = {properties[key]}'
  endfor
enddef

export def Health()
  echomsg 'SimpleEditorConfig health'
  echomsg $'  enabled: {Flag("simpleeditorconfig_enable", true) ? "yes" : "no"}'
  var remote = 'absent'
  if !Flag('simpleeditorconfig_remote', true)
    remote = 'disabled'
  elseif exists('*g:SimpleRemoteReadFile')
    remote = 'available'
  endif
  echomsg $'  remote reads: {remote}'
  var workspace = WorkspaceLine()
  echomsg '  workspace: ' .. (empty(workspace) ? 'none' : workspace)
  echomsg $'  remote cache: {len(s_remote_parsed)} file(s)'
  echomsg $'  sources: {len(get(b:, "simpleeditorconfig_sources", []))}'
enddef
