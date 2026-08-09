--[[
  Levititas v3.3 — Parser with Coverage Tracking
  src/parser/parser.lua

  Changes from v3:
    [1] Tracks total token count and consumed token count
    [2] Returns coverage metadata alongside AST
    [3] Never silently returns a partial AST
    [4] parse() returns: ast, err, coverage_info
    [5] coverage_info = { total=N, consumed=N, pct=N }
    [6] Caller must check coverage before proceeding
]]

local Spec = require("spec")

local Parser = {}
Parser.__index = Parser

-- ─────────────────────────────────────────────────────────────────────────────
-- §1  LEXER
-- ─────────────────────────────────────────────────────────────────────────────

local KEYWORDS = {}
for _, w in ipairs({
  "and","break","do","else","elseif","end","false","for",
  "function","goto","if","in","local","nil","not","or",
  "repeat","return","then","true","until","while"
}) do KEYWORDS[w] = true end

local function tokenize(src)
  local tokens, i, n, line = {}, 1, #src, 1
  local function adv(d) i = i + (d or 1) end
  local function peek(d) return src:sub(i, i + (d or 0)) end

  while i <= n do
    local c = peek()

    if c == '\n' then
      line = line + 1; adv()

    elseif c:match('%s') then
      adv()

    elseif c == '-' and peek(1) == '--' then
      -- Comment: consume but do NOT add to token stream
      if src:sub(i+2, i+3) == '[[' then
        local eq, k = 0, i + 3
        while src:sub(k,k) == '=' do eq = eq+1; k = k+1 end
        if src:sub(k,k) == '[' then
          local cl = ']' .. ('='):rep(eq) .. ']'
          local j = src:find(cl, k+1, true) or n-#cl+1
          i = j + #cl
        else
          local j = src:find('\n', i) or n; i = j
        end
      else
        local j = src:find('\n', i) or n; i = j
      end

    elseif c == '[' and src:sub(i+1,i+1):match('[%[=]') then
      local eq, k = 0, i+1
      while src:sub(k,k) == '=' do eq = eq+1; k = k+1 end
      if src:sub(k,k) == '[' then
        local cl = ']' .. ('='):rep(eq) .. ']'
        local j = src:find(cl, k+1, true) or n-#cl+1
        local s = src:sub(k+1, j-1)
        tokens[#tokens+1] = { t='string', v=s, line=line }
        i = j + #cl
      else
        tokens[#tokens+1] = { t='op', v=c, line=line }; adv()
      end

    elseif c == '"' or c == "'" then
      local q, j, s = c, i+1, ""
      while j <= n do
        local ch = src:sub(j,j)
        if ch == '\\' then
          local nc = src:sub(j+1,j+1)
          local esc = {n='\n',t='\t',r='\r',['\\']='\\',['\'']='"', ['"']='"',a='\a',b='\b',f='\f',v='\v'}
          if esc[nc] then s = s .. esc[nc]; j = j + 2
          elseif nc:match('%d') then
            local num = src:match('%d%d?%d?', j+1)
            s = s .. string.char(tonumber(num) or 0); j = j + 1 + #num
          else s = s .. nc; j = j + 2 end
        elseif ch == q then j = j + 1; break
        else s = s .. ch; j = j + 1 end
      end
      tokens[#tokens+1] = { t='string', v=s, line=line }; i = j

    elseif c:match('%d') or (c == '.' and src:sub(i+1,i+1):match('%d')) then
      local j = i
      if src:sub(j,j+1):match('0[xX]') then
        j = j + 2
        while src:sub(j,j):match('[%x_]') do j = j+1 end
      else
        while src:sub(j,j):match('[%d_]') do j = j+1 end
        if src:sub(j,j) == '.' then
          j = j + 1
          while src:sub(j,j):match('%d') do j = j+1 end
        end
        if src:sub(j,j):match('[eE]') then
          j = j+1
          if src:sub(j,j):match('[+-]') then j = j+1 end
          while src:sub(j,j):match('%d') do j = j+1 end
        end
      end
      local numStr = src:sub(i, j-1):gsub('_','')
      tokens[#tokens+1] = { t='number', v=tonumber(numStr) or 0, line=line }
      i = j

    elseif c:match('[%a_]') then
      local j = i
      while src:sub(j,j):match('[%w_]') do j = j+1 end
      local w = src:sub(i, j-1)
      tokens[#tokens+1] = {
        t    = KEYWORDS[w] and 'kw' or 'name',
        v    = w,
        line = line,
      }
      i = j

    else
      -- Operators — try multi-char first
      local matched = false
      for _, op in ipairs({
        "~=","==","<=",">=","..","::","//","<<",">>",
        "<<=",">>=","->","...",
      }) do
        if src:sub(i, i+#op-1) == op then
          tokens[#tokens+1] = { t='op', v=op, line=line }
          i = i + #op; matched = true; break
        end
      end
      if not matched then
        tokens[#tokens+1] = { t='op', v=c, line=line }; adv()
      end
    end
  end

  tokens[#tokens+1] = { t='eof', v='<eof>', line=line }
  return tokens
end

-- ─────────────────────────────────────────────────────────────────────────────
-- §2  PARSER STATE
-- ─────────────────────────────────────────────────────────────────────────────

function Parser.new(src)
  local self      = setmetatable({}, Parser)
  self.tokens     = tokenize(src)
  self.pos        = 1
  self.maxPos     = 1   -- track furthest position reached (for coverage)
  self.totalToks  = #self.tokens - 1  -- exclude EOF
  return self
end

function Parser:cur()
  self.maxPos = math.max(self.maxPos, self.pos)
  return self.tokens[self.pos]
end

function Parser:peek(d)
  return self.tokens[self.pos + (d or 1)]
end

function Parser:adv()
  local t = self.tokens[self.pos]
  self.pos = self.pos + 1
  self.maxPos = math.max(self.maxPos, self.pos)
  return t
end

function Parser:check(t, v)
  local c = self:cur()
  if v then return c.t == t and c.v == v end
  return c.t == t
end

function Parser:match(t, v)
  if self:check(t, v) then return self:adv() end
end

function Parser:expect(t, v)
  local c = self:cur()
  if v and (c.t ~= t or c.v ~= v) then
    error(string.format("[%s] line %d: expected %s '%s', got '%s'",
      Spec.ERR.PARSE_UNEXPECTED_TOKEN, c.line or 0, t, v, c.v))
  elseif not v and c.t ~= t then
    error(string.format("[%s] line %d: expected %s, got '%s' (%s)",
      Spec.ERR.PARSE_UNEXPECTED_TOKEN, c.line or 0, t, c.v, c.t))
  end
  return self:adv()
end

function Parser:coverage()
  return {
    total    = self.totalToks,
    consumed = self.maxPos - 1,
    pct      = self.totalToks > 0
               and math.floor((self.maxPos - 1) / self.totalToks * 100)
               or  100,
  }
end

-- ─────────────────────────────────────────────────────────────────────────────
-- §3  BLOCK / STATEMENT PARSING
-- ─────────────────────────────────────────────────────────────────────────────

local BLOCK_STOP = { ["end"]=true, ["else"]=true, ["elseif"]=true, ["until"]=true }

function Parser:parseBlock()
  local stmts = {}
  while true do
    local c = self:cur()
    if c.t == 'eof' then break end
    if c.t == 'kw' and BLOCK_STOP[c.v] then break end
    local s = self:parseStat()
    if s then stmts[#stmts+1] = s end
    self:match('op', ';')
    if s and s.type == 'Return' then break end
  end
  return { type='Block', body=stmts }
end

function Parser:parseStat()
  local c = self:cur()

  -- Skip bare semicolons
  if c.t == 'op' and c.v == ';' then self:adv(); return nil end

  if c.t == 'kw' then
    local v = c.v
    if     v == 'do'       then return self:parseDo()
    elseif v == 'while'    then return self:parseWhile()
    elseif v == 'repeat'   then return self:parseRepeat()
    elseif v == 'if'       then return self:parseIf()
    elseif v == 'for'      then return self:parseFor()
    elseif v == 'function' then return self:parseFuncStat()
    elseif v == 'local'    then return self:parseLocal()
    elseif v == 'return'   then return self:parseReturn()
    elseif v == 'break'    then self:adv(); return { type='Break' }
    elseif v == 'goto'     then
      self:adv()
      local name = self:expect('name').v
      return { type='Goto', label=name }
    end
  end

  if c.t == 'op' and c.v == '::' then
    self:adv()
    local name = self:expect('name').v
    self:expect('op', '::')
    return { type='Label', name=name }
  end

  return self:parseExprStat()
end

function Parser:parseDo()
  self:expect('kw','do')
  local b = self:parseBlock()
  self:expect('kw','end')
  return { type='Do', body=b }
end

function Parser:parseWhile()
  self:expect('kw','while')
  local cond = self:parseExpr()
  self:expect('kw','do')
  local body = self:parseBlock()
  self:expect('kw','end')
  return { type='While', cond=cond, body=body }
end

function Parser:parseRepeat()
  self:expect('kw','repeat')
  local body = self:parseBlock()
  self:expect('kw','until')
  local cond = self:parseExpr()
  return { type='Repeat', body=body, cond=cond }
end

function Parser:parseIf()
  self:expect('kw','if')
  local cond = self:parseExpr()
  self:expect('kw','then')
  local body = self:parseBlock()
  local elseifs, elsebody = {}, nil
  while self:check('kw','elseif') do
    self:adv()
    local ec = self:parseExpr()
    self:expect('kw','then')
    local eb = self:parseBlock()
    elseifs[#elseifs+1] = { cond=ec, body=eb }
  end
  if self:match('kw','else') then
    elsebody = self:parseBlock()
  end
  self:expect('kw','end')
  return { type='If', cond=cond, body=body, elseifs=elseifs, elsebody=elsebody }
end

function Parser:parseFor()
  self:expect('kw','for')
  local name = self:expect('name').v
  if self:match('op','=') then
    local start = self:parseExpr()
    self:expect('op',',')
    local limit = self:parseExpr()
    local step = nil
    if self:match('op',',') then step = self:parseExpr() end
    self:expect('kw','do')
    local body = self:parseBlock()
    self:expect('kw','end')
    return { type='ForNum', var=name, start=start, limit=limit, step=step, body=body }
  else
    local names = { name }
    while self:match('op',',') do names[#names+1] = self:expect('name').v end
    self:expect('kw','in')
    local iters = self:parseExprList()
    self:expect('kw','do')
    local body = self:parseBlock()
    self:expect('kw','end')
    return { type='ForGen', vars=names, iters=iters, body=body }
  end
end

function Parser:parseFuncStat()
  self:expect('kw','function')
  local name   = self:expect('name').v
  local fields = {}
  local method = nil
  while self:match('op','.') do fields[#fields+1] = self:expect('name').v end
  if self:match('op',':') then method = self:expect('name').v end
  local func = self:parseFuncBody(method ~= nil)
  return { type='Function', name=name, fields=fields, method=method, func=func }
end

function Parser:parseLocal()
  self:expect('kw','local')
  if self:check('kw','function') then
    self:adv()
    local name = self:expect('name').v
    local func = self:parseFuncBody(false)
    return { type='LocalFunction', name=name, func=func }
  end
  local names, attribs = {}, {}
  names[1]   = self:expect('name').v
  attribs[1] = self:parseAttrib()
  while self:match('op',',') do
    names[#names+1]   = self:expect('name').v
    attribs[#attribs+1] = self:parseAttrib()
  end
  local vals = {}
  if self:match('op','=') then vals = self:parseExprList() end
  return { type='Local', names=names, attribs=attribs, vals=vals }
end

function Parser:parseAttrib()
  if self:match('op','<') then
    local a = self:expect('name').v
    self:expect('op','>')
    return a
  end
  return nil
end

function Parser:parseReturn()
  self:expect('kw','return')
  local vals = {}
  local c = self:cur()
  local isStop = (c.t=='kw' and (c.v=='end' or c.v=='else' or c.v=='elseif' or c.v=='until'))
              or c.t == 'eof'
              or (c.t=='op' and c.v==';')
  if not isStop then
    vals = self:parseExprList()
  end
  self:match('op',';')
  return { type='Return', vals=vals }
end

function Parser:parseExprStat()
  local e = self:parseSuffixedExpr()
  if self:check('op','=') or self:check('op',',') then
    local targets = { e }
    while self:match('op',',') do
      targets[#targets+1] = self:parseSuffixedExpr()
    end
    self:expect('op','=')
    local vals = self:parseExprList()
    return { type='Assign', targets=targets, vals=vals }
  end
  -- Must be a function call
  if e.type ~= 'Call' and e.type ~= 'MethodCall' then
    local c = self:cur()
    error(string.format("[%s] line %d: expression is not a statement",
      Spec.ERR.PARSE_UNEXPECTED_TOKEN, c.line or 0))
  end
  return e
end

function Parser:parseFuncBody(hasself)
  self:expect('op','(')
  local params, vararg = {}, false
  if hasself then params[1] = 'self' end
  if not self:check('op',')') then
    if self:check('op','...') then
      self:adv(); vararg = true
    else
      params[#params+1] = self:expect('name').v
      while self:match('op',',') do
        if self:check('op','...') then self:adv(); vararg = true; break end
        params[#params+1] = self:expect('name').v
      end
    end
  end
  self:expect('op',')')
  local body = self:parseBlock()
  self:expect('kw','end')
  return { type='FuncBody', params=params, vararg=vararg, body=body }
end

function Parser:parseExprList()
  local exprs = { self:parseExpr() }
  while self:match('op',',') do exprs[#exprs+1] = self:parseExpr() end
  return exprs
end

-- ─────────────────────────────────────────────────────────────────────────────
-- §4  EXPRESSION PARSING (Pratt precedence climbing)
-- ─────────────────────────────────────────────────────────────────────────────

local BINOP_PREC = {
  ["or"]  = {1,1},  ["and"] = {2,2},
  ["<"]   = {3,3},  ["<="]  = {3,3},  [">"]  = {3,3},  [">="] = {3,3},
  ["=="]  = {3,3},  ["~="]  = {3,3},
  ["|"]   = {4,4},  ["~"]   = {5,5},  ["&"]  = {6,6},
  ["<<"]  = {7,7},  [">>"]  = {7,7},
  [".."]  = {8,9},  -- right-associative
  ["+"]   = {10,10}, ["-"]  = {10,10},
  ["*"]   = {11,11}, ["/"]  = {11,11}, ["//"] = {11,11}, ["%"] = {11,11},
  ["^"]   = {13,12}, -- right-associative
}

local UNOPS = { ["not"]=true, ["-"]=true, ["~"]=true, ["#"]=true }

function Parser:parseExpr(minPrec)
  minPrec = minPrec or 0
  local e = self:parseUnary()
  while true do
    local c = self:cur()
    local op = (c.t=='op' or c.t=='kw') and c.v
    local prec = op and BINOP_PREC[op]
    if not prec or prec[1] <= minPrec then break end
    self:adv()
    local right = self:parseExpr(prec[2])
    e = { type='Binop', op=op, left=e, right=right }
  end
  return e
end

function Parser:parseUnary()
  local c = self:cur()
  if (c.t=='op' or c.t=='kw') and UNOPS[c.v] then
    self:adv()
    return { type='Unop', op=c.v, operand=self:parseExpr(12) }
  end
  return self:parseSuffixedExpr()
end

function Parser:parseSuffixedExpr()
  local e = self:parsePrimaryExpr()
  while true do
    local c = self:cur()
    if c.t == 'op' and c.v == '.' then
      self:adv()
      local f = self:expect('name').v
      e = { type='Field', obj=e, field=f }
    elseif c.t == 'op' and c.v == '[' then
      self:adv()
      local idx = self:parseExpr()
      self:expect('op',']')
      e = { type='Index', obj=e, index=idx }
    elseif c.t == 'op' and c.v == ':' then
      self:adv()
      local m    = self:expect('name').v
      local args = self:parseCallArgs()
      e = { type='MethodCall', obj=e, method=m, args=args }
    elseif c.t=='op' and (c.v=='(' or c.v=='{') or c.t=='string' then
      local args = self:parseCallArgs()
      e = { type='Call', func=e, args=args }
    else
      break
    end
  end
  return e
end

function Parser:parsePrimaryExpr()
  local c = self:cur()
  if c.t == 'name' then
    self:adv(); return { type='Name', name=c.v }
  elseif c.t == 'op' and c.v == '(' then
    self:adv()
    local e = self:parseExpr()
    self:expect('op',')')
    return e
  end
  return self:parseSimpleExpr()
end

function Parser:parseSimpleExpr()
  local c = self:cur()
  if     c.t == 'number' then self:adv(); return { type='Number', val=c.v }
  elseif c.t == 'string' then self:adv(); return { type='String', val=c.v }
  elseif c.t == 'kw' and c.v == 'true'     then self:adv(); return { type='Bool', val=true }
  elseif c.t == 'kw' and c.v == 'false'    then self:adv(); return { type='Bool', val=false }
  elseif c.t == 'kw' and c.v == 'nil'      then self:adv(); return { type='Nil' }
  elseif c.t == 'op' and c.v == '...'      then self:adv(); return { type='Vararg' }
  elseif c.t == 'kw' and c.v == 'function' then
    self:adv(); return self:parseFuncBody(false)
  elseif c.t == 'op' and c.v == '{' then
    return self:parseTable()
  end
  error(string.format("[%s] line %d: unexpected token '%s' (%s)",
    Spec.ERR.PARSE_UNEXPECTED_TOKEN, c.line or 0, c.v, c.t))
end

function Parser:parseCallArgs()
  local c = self:cur()
  if c.t == 'op' and c.v == '(' then
    self:adv()
    if self:check('op',')') then self:adv(); return {} end
    local args = self:parseExprList()
    self:expect('op',')')
    return args
  elseif c.t == 'op' and c.v == '{' then
    return { self:parseTable() }
  elseif c.t == 'string' then
    self:adv(); return { { type='String', val=c.v } }
  end
  error(string.format("[%s] line %d: expected function arguments, got '%s'",
    Spec.ERR.PARSE_UNEXPECTED_TOKEN, c.line or 0, c.v))
end

function Parser:parseTable()
  self:expect('op','{')
  local fields = {}
  while not self:check('op','}') do
    local f
    if self:check('op','[') then
      self:adv()
      local k = self:parseExpr()
      self:expect('op',']')
      self:expect('op','=')
      local v = self:parseExpr()
      f = { type='TableField', key=k, val=v }
    elseif self:check('name') and self:peek().t=='op' and self:peek().v=='=' then
      local k = self:adv().v
      self:adv()  -- consume '='
      local v = self:parseExpr()
      f = { type='TableField', key={ type='String', val=k }, val=v }
    else
      local v = self:parseExpr()
      f = { type='TableField', key=nil, val=v }
    end
    fields[#fields+1] = f
    if not self:match('op',',') then self:match('op',';') end
    if self:check('op','}') then break end
  end
  self:expect('op','}')
  return { type='Table', fields=fields }
end

-- ─────────────────────────────────────────────────────────────────────────────
-- §5  PUBLIC API
-- ─────────────────────────────────────────────────────────────────────────────

-- Returns: ast, err_msg, coverage_info
-- If err_msg is non-nil, ast is nil and obfuscation must be aborted.
-- coverage_info is always returned for diagnostics.
function Parser.parse(src)
  local p = Parser.new(src)
  local ok, result = pcall(function()
    return p:parseBlock()
  end)

  local coverage = p:coverage()

  if not ok then
    return nil,
      string.format("[%s] Parse failed: %s", Spec.ERR.PARSE_UNEXPECTED_TOKEN, result),
      coverage
  end

  -- Coverage check: consumed must equal total (all tokens parsed)
  if coverage.consumed < coverage.total then
    return nil,
      string.format(
        "[%s] Incomplete parse: consumed %d/%d tokens (%.0f%%). " ..
        "Unsupported syntax detected near token %d. " ..
        "Obfuscation aborted — protection would be incomplete.",
        Spec.ERR.PARSE_COVERAGE_FAIL,
        coverage.consumed, coverage.total, coverage.pct,
        coverage.consumed + 1),
      coverage
  end

  return result, nil, coverage
end

return Parser
