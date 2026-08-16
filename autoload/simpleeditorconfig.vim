vim9script

var s_generation = 0

def Warn(message: string)
  echohl WarningMsg
  echomsg '[SimpleEditorConfig] ' .. message
  echohl None
enddef

def Parse(lines: list<string>): dict<any>
  var result: dict<any> = {root: false, sections: []}
  var current: dict<any> = {}
  for raw in lines
    var line = trim(raw)
    if empty(line) || line =~# '^[#;]'
      continue
    endif
    if line =~# '^\[.*\]$'
      current = {
        pattern: strpart(line, 1, strlen(line) - 2),
        properties: {},
      }
      add(result.sections, current)
      continue
    endif
    var separator = match(line, '[:=]')
    if separator < 0
      continue
    endif
    var key = tolower(trim(strpart(line, 0, separator)))
    var value = tolower(trim(strpart(line, separator + 1)))
    if empty(current)
      if key ==# 'root'
        result.root = value ==# 'true'
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

# Compiled section globs keyed by the raw pattern, holding the regex and the
# bounds of every {n..m} range in it.  Compiling is a pure function of the
# pattern and a project reuses the same handful of patterns for every buffer it
# opens, so this only ever grows by the number of distinct patterns a session
# has seen.
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

# Compile one glob into a Vim regex fragment, appending the bounds of every
# {n..m} it contains to `ranges` in the left-to-right order of the capture
# groups it emits for them.  Works on a list of characters rather than the
# string so that a multibyte pattern indexes the same way an ASCII one does.
def CompileGlob(chars: list<string>, ranges: list<list<number>>): string
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
        # A range cannot become an alternation of the integers in it —
        # `{1..9999}` would be 9999 branches — so the regex captures the digits
        # and SectionMatches() compares them numerically.  Vim only has nine
        # capture groups, so a tenth range in one pattern matches any integer
        # unchecked; that is a wider match than the spec asks for, and it beats
        # raising E872 from inside a BufReadPost.
        if len(ranges) < 9
          out ..= '\([-+]\?\d\+\)'
          add(ranges, [str2nr(bounds[1]), str2nr(bounds[2])])
        else
          out ..= '\%([-+]\?\d\+\)'
        endif
      else
        var choices = SplitChoices(body)
        if len(choices) == 1
          out ..= '{' .. CompileGlob(choices[0], ranges) .. '}'
        else
          var alternatives: list<string> = []
          for choice in choices
            add(alternatives, CompileGlob(choice, ranges))
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
  var ranges: list<list<number>> = []
  var compiled: dict<any> = {regex: '', ranges: ranges, usable: true}
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
      .. CompileGlob(split(glob, '\zs'), ranges) .. '$'
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
  if empty(compiled.ranges)
    return relative =~# compiled.regex
  endif
  var matched = matchlist(relative, compiled.regex)
  if empty(matched)
    return false
  endif
  var group = 1
  for bounds in compiled.ranges
    var digits = matched[group]
    group += 1
    if empty(digits)
      # This range sat in a brace alternative that was not the one taken.
      continue
    endif
    if digits =~# '^[-+]\?0\d'
      # A name spelled 007 is not the integer 7 for the purpose of `{1..100}`.
      return false
    endif
    var value = str2nr(digits)
    if value < bounds[0] || value > bounds[1]
      return false
    endif
  endfor
  return true
enddef

def Effective(configs: list<dict<any>>, path: string): dict<string>
  var properties: dict<string> = {}
  for config in configs
    for section in config.parsed.sections
      if !SectionMatches(section.pattern, config.dir, path)
        continue
      endif
      for [key, value] in items(section.properties)
        if value ==# 'unset'
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
    return existing
  endif
  var baseline = {
    expandtab: getbufvar(buf, '&expandtab'),
    shiftwidth: getbufvar(buf, '&shiftwidth'),
    softtabstop: getbufvar(buf, '&softtabstop'),
    tabstop: getbufvar(buf, '&tabstop'),
    fileformat: getbufvar(buf, '&fileformat'),
    fileencoding: getbufvar(buf, '&fileencoding'),
    textwidth: getbufvar(buf, '&textwidth'),
    fixendofline: getbufvar(buf, '&fixendofline'),
    endofline: getbufvar(buf, '&endofline'),
  }
  setbufvar(buf, 'simpleeditorconfig_baseline', baseline)
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

def ApplyProperties(buf: number, properties: dict<string>, sources: list<string>)
  if !bufexists(buf)
    return
  endif
  RestoreBaseline(buf)
  var tab_width = Positive(get(properties, 'tab_width', ''))
  var indent_size = get(properties, 'indent_size', '') ==# 'tab'
    ? tab_width : Positive(get(properties, 'indent_size', ''))
  if get(properties, 'indent_style', '') ==# 'space'
    SetOption(buf, 'expandtab', 1)
  elseif get(properties, 'indent_style', '') ==# 'tab'
    SetOption(buf, 'expandtab', 0)
  endif
  if tab_width > 0
    SetOption(buf, 'tabstop', tab_width)
  endif
  if indent_size > 0
    SetOption(buf, 'shiftwidth', indent_size)
    SetOption(buf, 'softtabstop', indent_size)
    if tab_width == 0 && get(properties, 'indent_style', '') ==# 'space'
      SetOption(buf, 'tabstop', indent_size)
    endif
  endif
  var endings = {lf: 'unix', crlf: 'dos', cr: 'mac'}
  var ending = get(properties, 'end_of_line', '')
  if has_key(endings, ending)
    SetOption(buf, 'fileformat', endings[ending])
  endif
  var charsets = {
    'utf-8': 'utf-8',
    'utf-8-bom': 'utf-8',
    latin1: 'latin1',
    'utf-16be': 'ucs-2be',
    'utf-16le': 'ucs-2le',
  }
  var charset = get(properties, 'charset', '')
  if has_key(charsets, charset)
    SetOption(buf, 'fileencoding', charsets[charset])
    setbufvar(buf, 'simpleeditorconfig_bomb', charset ==# 'utf-8-bom')
  endif
  var maximum = get(properties, 'max_line_length', '')
  if maximum ==# 'off'
    SetOption(buf, 'textwidth', 0)
  elseif Positive(maximum) > 0
    SetOption(buf, 'textwidth', Positive(maximum))
  endif
  if has_key(properties, 'insert_final_newline')
    var final_newline = properties.insert_final_newline ==# 'true'
    SetOption(buf, 'fixendofline', final_newline ? 1 : 0)
    if final_newline
      SetOption(buf, 'endofline', 1)
    endif
  endif
  setbufvar(buf, 'simpleeditorconfig', properties)
  setbufvar(buf, 'simpleeditorconfig_sources', sources)
  setbufvar(buf, 'simpleeditorconfig_trim',
    get(properties, 'trim_trailing_whitespace', '') ==# 'true')
  if get(g:, 'simpleeditorconfig_verbose', 0)
    echomsg printf('[SimpleEditorConfig] %s: %d properties from %d file(s)',
      bufname(buf), len(properties), len(sources))
  endif
enddef

# Parsed .editorconfig files keyed by their full path.  Every file opened in a
# project re-walks the same directories and re-reads the same .editorconfig that
# the file before it read; with matching down to one compiled regex, reading and
# parsing is what is left on the BufReadPost path.
#
# A stale .editorconfig is worse than reading one again, so an entry is reused
# only when the file's mtime and size are still exactly what they were when it
# was read — and it is not stored at all while that mtime is the current second.
# getftime() has one-second resolution, so a write landing in the same second as
# our read would otherwise be invisible for as long as the session lives, which
# is exactly the sequence "edit .editorconfig, save, open a file to see what it
# did".  Once the second has passed, any later write must produce a different
# mtime, and the entry falls out on its own.
var s_parsed: dict<dict<any>> = {}

def ParseFile(file: string): dict<any>
  var ftime = getftime(file)
  var size = getfsize(file)
  var cached = get(s_parsed, file, {})
  if !empty(cached) && cached.ftime == ftime && cached.size == size
    return cached.parsed
  endif
  var parsed = Parse(readfile(file))
  if ftime != localtime()
    s_parsed[file] = {ftime: ftime, size: size, parsed: parsed}
  endif
  return parsed
enddef

def LocalConfigs(path: string): list<dict<any>>
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
    var parent = fnamemodify(dir, ':h')
    if parent ==# dir
      break
    endif
    dir = parent
  endwhile
  return reverse(configs)
enddef

def FinishRemote(buf: number, path: string, configs: list<dict<any>>, token: number)
  if !bufexists(buf) || getbufvar(buf, 'simpleeditorconfig_token', -1) != token
    return
  endif
  var ordered = reverse(configs)
  ApplyProperties(buf, Effective(ordered, path),
    mapnew(ordered, (_, config) => config.path))
enddef

def RemoteStep(buf: number, path: string, dir: string, root: string,
    configs: list<dict<any>>, token: number)
  if !bufexists(buf) || getbufvar(buf, 'simpleeditorconfig_token', -1) != token
    return
  endif
  var file = (dir ==# '/' ? '' : dir) .. '/.editorconfig'
  g:SimpleRemoteReadFile(file, (ok, body) => {
    var stop = false
    if ok
      var parsed = Parse(split(body, "\n", 1))
      add(configs, {dir: dir, path: file, parsed: parsed})
      stop = parsed.root
    endif
    if stop || dir ==# root
      FinishRemote(buf, path, configs, token)
      return
    endif
    var parent = fnamemodify(dir, ':h')
    if parent ==# dir || strlen(parent) < strlen(root)
      FinishRemote(buf, path, configs, token)
      return
    endif
    RemoteStep(buf, path, parent, root, configs, token)
  })
enddef

def ApplyRemote(buf: number, path: string)
  if !get(g:, 'simpleeditorconfig_remote', 1)
      || !exists('*g:SimpleRemoteReadFile')
    return
  endif
  var workspace = get(g:, 'simpleremote_workspace', {})
  var root = substitute(get(workspace, 'root', ''), '/\+$', '', '')
  if root ==# ''
    root = '/'
  endif
  var prefix = root ==# '/' ? '/' : root .. '/'
  if path !=# root && stridx(path, prefix) != 0
    return
  endif
  s_generation += 1
  var token = s_generation
  setbufvar(buf, 'simpleeditorconfig_token', token)
  RemoteStep(buf, path, fnamemodify(path, ':h'), root, [], token)
enddef

export def Apply(buf: number = bufnr())
  if !get(g:, 'simpleeditorconfig_enable', 1) || !bufexists(buf)
      || getbufvar(buf, '&buftype') !~# '^\%(\|acwrite\)$'
    return
  endif
  var remote = getbufvar(buf, 'vimrc_remote', {})
  if type(remote) == v:t_dict && !empty(get(remote, 'path', ''))
    ApplyRemote(buf, remote.path)
    return
  endif
  var name = bufname(buf)
  if empty(name)
    return
  endif
  var path = resolve(fnamemodify(name, ':p'))
  var configs = LocalConfigs(path)
  ApplyProperties(buf, Effective(configs, path),
    mapnew(configs, (_, config) => config.path))
enddef

export def ApplyRemoteEvent()
  var event = get(g:, 'simpleremote_event', {})
  if get(event, 'type', '') ==# 'buffer-read'
    Apply(get(event, 'bufnr', -1))
  endif
enddef

export def BeforeWrite()
  if !get(b:, 'simpleeditorconfig_trim', false) || !&l:modifiable || &l:readonly
    return
  endif
  var view = winsaveview()
  try
    silent! keepjumps keeppatterns :%substitute/\s\+$//e
  finally
    winrestview(view)
  endtry
  if get(b:, 'simpleeditorconfig_bomb', false)
    setlocal bomb
  endif
enddef

export def Info()
  var properties = get(b:, 'simpleeditorconfig', {})
  echomsg $'SimpleEditorConfig: {bufname()}'
  for source in get(b:, 'simpleeditorconfig_sources', [])
    echomsg '  source: ' .. source
  endfor
  for key in sort(keys(properties))
    echomsg $'  {key} = {properties[key]}'
  endfor
enddef

export def Health()
  echomsg 'SimpleEditorConfig health'
  echomsg $'  enabled: {get(g:, "simpleeditorconfig_enable", 1) ? "yes" : "no"}'
  echomsg $'  remote reads: {exists("*g:SimpleRemoteReadFile") ? "available" : "absent"}'
  echomsg $'  sources: {len(get(b:, "simpleeditorconfig_sources", []))}'
enddef
