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

def ExpandBraces(pattern: string): list<string>
  var opening = match(pattern, '{[^{}]*}')
  if opening < 0
    return [pattern]
  endif
  var closing = matchend(pattern, '{[^{}]*}', opening)
  var body = strpart(pattern, opening + 1, closing - opening - 2)
  var choices = split(body, ',', 1)
  if len(choices) <= 1
    return [pattern]
  endif
  var expanded: list<string> = []
  for choice in choices
    extend(expanded, ExpandBraces(
      strpart(pattern, 0, opening) .. choice .. strpart(pattern, closing)))
  endfor
  return expanded
enddef

def SectionMatches(pattern: string, config_dir: string, path: string): bool
  var relative = path ==# config_dir ? fnamemodify(path, ':t')
    : substitute(strpart(path, strlen(config_dir)), '^/', '', '')
  for candidate in ExpandBraces(pattern)
    var normalized = substitute(candidate, '^/', '', '')
    var subject = normalized =~# '/' ? relative : fnamemodify(path, ':t')
    if subject =~# glob2regpat(normalized)
      return true
    endif
  endfor
  return false
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
          remove(properties, key)
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

def LocalConfigs(path: string): list<dict<any>>
  var configs: list<dict<any>> = []
  var dir = fnamemodify(path, ':h')
  while !empty(dir)
    var file = dir .. '/.editorconfig'
    if filereadable(file)
      var parsed = Parse(readfile(file))
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
