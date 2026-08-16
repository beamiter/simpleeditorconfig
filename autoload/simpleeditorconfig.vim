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
# any later write must produce a different mtime, and the entry falls out on
# its own.
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

# Remote .editorconfig files, parsed, keyed by workspace id and remote path.
# Every remote:// buffer a project opens walks the same directories up to
# the same workspace root, and each directory used to cost one agent
# round-trip — the file at depth d paid d of them, serially, before its
# options landed.  A miss is cached as well as a hit, because most
# directories have no .editorconfig and "not there" is the answer that is
# asked for most.
#
# There is no mtime to check against as there is for the local cache, so the
# entries are dropped whenever something is known to have changed them: a
# remote:// buffer saving a .editorconfig (BufWritePost), a tree or API
# mutation touching one (SimpleRemoteFilesChanged), the workspace being
# swapped for another (SimpleRemoteWorkspaceChanged) or going away
# (SimpleRemoteDisconnected), and :SimpleEditorConfigReload, which is the
# user asking for a re-read.  The workspace id in the key keeps a reconnect
# from ever seeing the previous connection's answers.
var s_remote_parsed: dict<dict<any>> = {}

# Emptying the cache is not enough on its own, because a walk that is on the
# wire when it happens answers afterwards with what the file said *before* the
# change, and publishing that re-fills the cache with exactly the copy the
# invalidation threw away — for the rest of the session, since nothing asks
# again.  That is not a theoretical ordering either: a SimpleRemoteFilesChanged
# from an upload's own scp job, or a SimpleRemoteWorkspaceChanged from
# :SimpleRemoteTreeSetRoot, is emitted from somewhere other than the agent
# channel the reads travel on, and lands between them.
#
# So every invalidation bumps this counter, a walk remembers the value it was
# started under, and an answer from an older one still configures its own
# buffer — that is what the buffer asked for — but is never published to the
# cache, where it would configure buffers opened after the change.
var s_remote_epoch = 0

def RemoteKey(workspace: dict<any>, file: string): string
  return string(get(workspace, 'id', '')) .. ':' .. file
enddef

def RemoteFile(dir: string): string
  return (dir ==# '/' ? '' : dir) .. '/.editorconfig'
enddef

# Drop every cached remote .editorconfig.
export def ForgetRemote()
  s_remote_parsed = {}
  s_remote_epoch += 1
enddef

# Drop the cached entries a change to `paths` may have touched: a
# .editorconfig itself, or a directory that was created, renamed or deleted
# with .editorconfig files somewhere under it.
#
# An empty cache is not a reason to return early: a walk may be in flight with
# answers that predate this change, and the epoch is what keeps them out of
# the cache.  It is bumped once for any report carrying a usable path, even
# one that removed nothing — whether a directory the report names holds an
# .editorconfig a walk is reading right now is not knowable from here, and the
# price of assuming it does is that one walk's answers are read again.
def ForgetRemotePaths(paths: list<string>)
  var touched = false
  for path in paths
    if type(path) != v:t_string || empty(path)
      continue
    endif
    touched = true
    if path =~# '/\.editorconfig$' || path ==# '.editorconfig'
      s_remote_parsed = {}
      s_remote_epoch += 1
      return
    endif
    var prefix = substitute(path, '/\+$', '', '') .. '/'
    for key in keys(s_remote_parsed)
      var file = strpart(key, stridx(key, ':') + 1)
      if stridx(file, prefix) == 0
        remove(s_remote_parsed, key)
      endif
    endfor
  endfor
  if touched
    s_remote_epoch += 1
  endif
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

def FinishRemote(buf: number, path: string, configs: list<dict<any>>, token: number)
  if !bufexists(buf) || getbufvar(buf, 'simpleeditorconfig_token', -1) != token
    return
  endif
  var ordered = reverse(configs)
  ApplyProperties(buf, Effective(ordered, path),
    mapnew(ordered, (_, config) => config.path))
enddef

# Once every directory has answered, keep the configs from the file's own
# directory up to the first one that says `root = true` and apply them.
#
# A directory that failed to answer only matters inside the range that cut
# keeps.  The walk asks every directory up to the workspace root at once, so
# it also asks the ones a `root = true` further down makes irrelevant, and a
# timeout or an unreadable directory up there says nothing about the part of
# the picture that decides this file — the sequential walk this replaced never
# even looked at it.  Below the cut it is the opposite: a child .editorconfig
# without the root one it builds on is an incoherent set, worse than the
# buffer's own defaults, so nothing is applied.
def MaybeFinish(state: dict<any>)
  if state.done || state.answered < len(state.dirs)
    return
  endif
  state.done = true
  var configs: list<dict<any>> = []
  for idx in range(len(state.dirs))
    var entry = state.results[idx]
    if get(entry, 'failed', false)
      return
    endif
    if !entry.ok
      continue
    endif
    add(configs, {dir: state.dirs[idx], path: RemoteFile(state.dirs[idx]),
      parsed: entry.parsed})
    if entry.parsed.root
      break
    endif
  endfor
  FinishRemote(state.buf, state.path, configs, state.token)
enddef

# One directory's answer.  The agent's "no such file" reply is `not a file:
# <path>`; every other failure — connection closed, workspace not ready,
# request timed out, cannot read — is recorded against that one directory and
# left out of the cache, for MaybeFinish() to weigh against where the walk is
# cut.
def OnRead(state: dict<any>, idx: number, ok: bool, body: string)
  if state.done
    return
  endif
  var entry: dict<any>
  if !ok && body !~# '^not a file:'
    entry = {ok: false, failed: true, parsed: {}}
  else
    entry = {ok: ok, failed: false,
      parsed: ok ? Parse(split(body, "\n", 1)) : {}}
    if state.epoch == s_remote_epoch
      var key = RemoteKey(state.workspace, RemoteFile(state.dirs[idx]))
      s_remote_parsed[key] = entry
    endif
  endif
  state.results[idx] = entry
  state.answered += 1
  MaybeFinish(state)
enddef

# A named function so the closure captures this call's `idx` and nothing
# else.  Returns false when the read could not even be issued.
def IssueRead(state: dict<any>, idx: number): bool
  var file = RemoteFile(state.dirs[idx])
  return g:SimpleRemoteReadFile(file, (ok, body) =>
    OnRead(state, idx, !!ok, type(body) == v:t_string ? body : string(body))) >= 0
enddef

# Ask for every candidate .editorconfig at once — the reads are independent,
# so a file at depth d costs one round-trip instead of d — answering the
# ones already cached on the spot.
def Collect(buf: number, path: string, dirs: list<string>,
    workspace: dict<any>, token: number)
  var state: dict<any> = {buf: buf, path: path, dirs: dirs, token: token,
    workspace: workspace, results: repeat([{}], len(dirs)), answered: 0,
    done: false, epoch: s_remote_epoch}
  for idx in range(len(dirs))
    var cached = get(s_remote_parsed, RemoteKey(workspace, RemoteFile(dirs[idx])), {})
    if !empty(cached)
      state.results[idx] = cached
      state.answered += 1
    endif
  endfor
  for idx in range(len(dirs))
    if !empty(state.results[idx])
      continue
    endif
    if !IssueRead(state, idx)
      # Refused outright: the workspace is not ready, so the directories not
      # asked for yet would be refused too and nothing is applied.
      state.done = true
      return
    endif
    if state.done
      # Every directory answered on the spot and the walk has already
      # finished.
      return
    endif
  endfor
  MaybeFinish(state)
enddef

def ApplyRemote(buf: number, path: string)
  if !get(g:, 'simpleeditorconfig_remote', 1)
      || !exists('*g:SimpleRemoteReadFile')
    return
  endif
  var workspace = get(g:, 'simpleremote_workspace', {})
  if type(workspace) != v:t_dict
    workspace = {}
  endif
  var root = substitute(get(workspace, 'root', ''), '/\+$', '', '')
  if root ==# ''
    root = '/'
  endif
  if !UnderRoot(path, root)
    return
  endif
  s_generation += 1
  var token = s_generation
  setbufvar(buf, 'simpleeditorconfig_token', token)
  Collect(buf, path, RemoteDirs(path, root), workspace, token)
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
  var configs = LocalConfigs(path, ProjectionRoot(path))
  ApplyProperties(buf, Effective(configs, path),
    mapnew(configs, (_, config) => config.path))
enddef

# :SimpleEditorConfigReload — the user asking for a fresh read, so the cached
# remote answers are dropped first; the local cache checks mtimes itself.
export def Reload(buf: number = bufnr())
  ForgetRemote()
  Apply(buf)
enddef

export def ApplyRemoteEvent()
  var event = get(g:, 'simpleremote_event', {})
  if get(event, 'type', '') ==# 'buffer-read'
    Apply(get(event, 'bufnr', -1))
  endif
enddef

# User SimpleRemoteFilesChanged: a tree, upload or API mutation.  Only a
# change that can have touched a .editorconfig costs anything.
export def OnRemoteFilesChanged()
  var event = get(g:, 'simpleremote_event', {})
  var changes = get(event, 'changes', [])
  if type(changes) != v:t_list
    return
  endif
  var paths: list<string> = []
  for change in changes
    if type(change) == v:t_dict && type(get(change, 'path', '')) == v:t_string
      add(paths, get(change, 'path', ''))
    endif
  endfor
  ForgetRemotePaths(paths)
enddef

# BufWritePost: a remote:// buffer that saved a .editorconfig has just made
# the cached copy of it stale.  Local .editorconfig files are covered by the
# mtime check in ParseFile().
export def AfterWrite()
  var remote = get(b:, 'vimrc_remote', {})
  if type(remote) == v:t_dict && get(remote, 'path', '') =~# '/\.editorconfig$'
    ForgetRemotePaths([remote.path])
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
  echomsg $'  enabled: {get(g:, "simpleeditorconfig_enable", 1) ? "yes" : "no"}'
  echomsg $'  remote reads: {exists("*g:SimpleRemoteReadFile") ? "available" : "absent"}'
  var workspace = WorkspaceLine()
  echomsg '  workspace: ' .. (empty(workspace) ? 'none' : workspace)
  echomsg $'  remote cache: {len(s_remote_parsed)} file(s)'
  echomsg $'  sources: {len(get(b:, "simpleeditorconfig_sources", []))}'
enddef
