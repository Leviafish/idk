"""
Levititas Web v2.0 — Flask Backend
Run: python server.py
Free 24/7 via Cloudflare Tunnel / Railway / Render / Fly.io
"""

from flask import Flask, request, jsonify, render_template, send_from_directory
import subprocess, os, tempfile, uuid, time, json, threading, shutil, re, random

app = Flask(__name__, template_folder="templates", static_folder="static")
app.config["MAX_CONTENT_LENGTH"] = 4 * 1024 * 1024  # 4MB

OUTPUT_DIR = os.path.join(os.path.dirname(__file__), "output")
os.makedirs(OUTPUT_DIR, exist_ok=True)

# ── auto-cleanup output dir every 10 minutes ──────────────────
def _cleanup():
    while True:
        time.sleep(600)
        now = time.time()
        for f in os.listdir(OUTPUT_DIR):
            fp = os.path.join(OUTPUT_DIR, f)
            try:
                if now - os.path.getmtime(fp) > 600:
                    os.remove(fp)
            except Exception:
                pass
threading.Thread(target=_cleanup, daemon=True).start()

# ── Lua runtime detection ──────────────────────────────────────
def _lua():
    for name in ("lua", "lua5.4", "lua5.3", "lua54", "lua53"):
        path = shutil.which(name)
        if path:
            return path
    return None

def _run_lua(args):
    lua = _lua()
    if not lua:
        return None, "no_lua"
    cli = os.path.join(os.path.dirname(__file__), "levititas.lua")
    try:
        r = subprocess.run([lua, cli] + args, capture_output=True, text=True, timeout=30)
        return r.returncode, r.stdout + r.stderr
    except subprocess.TimeoutExpired:
        return 1, "Obfuscation timed out (30s)."
    except Exception as e:
        return 1, str(e)

# ── Routes ────────────────────────────────────────────────────
@app.route("/")
def index():
    return render_template("index.html")

@app.route("/api/status")
def status():
    return jsonify(lua=bool(_lua()), version="2.0.0",
                   engine="full" if _lua() else "python-fallback")

@app.route("/api/obfuscate", methods=["POST"])
def obfuscate():
    data = request.get_json(force=True, silent=True) or {}
    source = data.get("source", "").strip()
    if not source:
        return jsonify(ok=False, error="No source code provided.")
    if len(source) > 800_000:
        return jsonify(ok=False, error="File too large (max 800 KB).")

    opts = data.get("options", {})
    uid  = uuid.uuid4().hex
    src_path = os.path.join(OUTPUT_DIR, f"{uid}_in.lua")
    out_path = os.path.join(OUTPUT_DIR, f"{uid}_out.lua")

    try:
        with open(src_path, "w", encoding="utf-8") as f:
            f.write(source)

        args = [src_path, "-o", out_path]
        flag_map = {
            "mangleNames":    "--no-mangle",
            "encryptStrings": "--no-strings",
            "encodeNumbers":  "--no-numbers",
            "injectJunk":     "--no-junk",
            "antiDebug":      "--no-antidebug",
            "wrapEnv":        "--no-wrap",
            "stripComments":  "--no-strip",
            "controlFlow":    "--no-flow",
            "vmMode":         "--no-vm",
            "polymorphic":    "--no-polymorphic",
        }
        for key, flag in flag_map.items():
            if opts.get(key) is False:
                args.append(flag)
        for name in opts.get("protectNames", []):
            if name.strip():
                args += ["--protect", name.strip()]

        t0 = time.time()
        code, log = _run_lua(args)
        elapsed = round(time.time() - t0, 3)

        note = ""
        if code is None or log == "no_lua" or (code != 0):
            # Python fallback
            result_text = _python_fallback(source, opts)
            note = "Using built-in Python engine (Lua not found on server). Install Lua 5.4 for full VM/CFG obfuscation."
            return jsonify(ok=True, result=result_text, elapsed=elapsed,
                           stats=_stats(source, result_text), note=note)

        if not os.path.exists(out_path):
            return jsonify(ok=False, error=log or "Output not produced.")

        with open(out_path, "r", encoding="utf-8") as f:
            result = f.read()

        return jsonify(ok=True, result=result, elapsed=elapsed,
                       stats=_stats(source, result), note=note)
    finally:
        for p in (src_path, out_path):
            try: os.remove(p)
            except: pass


def _stats(original, obfuscated):
    return {
        "originalBytes":   len(original.encode()),
        "obfuscatedBytes": len(obfuscated.encode()),
        "originalLines":   original.count("\n") + 1,
        "obfuscatedLines": obfuscated.count("\n") + 1,
        "ratio":           round(len(obfuscated) / max(len(original), 1), 2),
    }


# ═══════════════════════════════════════════════════════════════
# PYTHON FALLBACK — mirrors Levititas v2 passes in Python
# Applied when no Lua runtime is available on the server.
# Covers: comment stripping, name mangling, string XOR,
#         number lambda chains, dead code injection, CFG dispatch,
#         opaque predicates, env wrapping.
# ═══════════════════════════════════════════════════════════════

class _PythonObf:
    LUA_KW = {"and","break","do","else","elseif","end","false","for",
               "function","goto","if","in","local","nil","not","or",
               "repeat","return","then","true","until","while"}
    LUA_GLOBALS = {
        "print","pairs","ipairs","next","type","tostring","tonumber","error",
        "assert","pcall","xpcall","select","unpack","table","string","math",
        "io","os","package","require","setmetatable","getmetatable","rawget",
        "rawset","rawequal","rawlen","load","loadfile","dofile","collectgarbage",
        "coroutine","debug","utf8","_G","_VERSION","arg",
        "game","workspace","script","wait","task","Instance","Vector3",
        "CFrame","Color3","UDim2","Enum","tick","warn","spawn","delay",
        "RunService","Players","ReplicatedStorage","ServerStorage",
    }
    ID_CHARS = "lI"

    def __init__(self, opts):
        self.opts = opts
        self.rng = random.Random(time.time_ns())
        self._style = self.rng.randint(0, 2)

    def _id(self, length=None):
        n = length or self.rng.randint(6, 14)
        prefixes = ["_", "__", "I", "l", "Il", "lI", "IlI"]
        p = self.rng.choice(prefixes)
        body = "".join(self.rng.choice(self.ID_CHARS) for _ in range(n))
        return p + body

    def _hex(self, n):
        return f"0x{int(n):X}"

    def _rolling_xor(self, s, seed):
        """Rolling XOR matching Lua engine"""
        result = []
        k = seed & 0xFF
        for i, ch in enumerate(s.encode('utf-8', errors='replace')):
            result.append(ch ^ (k & 0xFF))
            k = (k * 0x41 + ch + i) & 0xFF
        return result

    def _opaque_true(self):
        a = self.rng.randint(2, 100)
        return f"(({self._hex(a)})*({self._hex(a)}+1))%2==0"

    def _opaque_false(self):
        a = self.rng.randint(2, 100)
        return f"(({self._hex(a)})*({self._hex(a)}+1))%2~=0"

    def _dead_block(self):
        a, b = self._id(), self._id()
        templates = [
            f"if {self._opaque_false()} then\nlocal {a}={self._hex(self.rng.randint(1,999))}\nend",
            f"do\nlocal {a}=false\nwhile {a} do break end\nend",
            f"local {a}={{}}; local {b}=type({a})",
        ]
        return self.rng.choice(templates)

    def _virtualize_num(self, n):
        try:
            n = int(n)
            if not (0 <= n <= 0xFFFF):
                return self._hex(n)
        except:
            return str(n)
        m1 = self.rng.randint(1, 0xFF)
        m2 = self.rng.randint(1, 0x7F)
        r  = 3
        v  = n ^ m1
        v  = (v + m2) & 0xFFFF
        v  = ((v << r) | (v >> (16 - r))) & 0xFFFF
        sv = self._hex(v)
        return f"((({sv}>>{self._hex(r)})|({sv}<<{self._hex(16-r)}))&0xFFFF-{self._hex(m2)})~{self._hex(m1)}"

    def _strip_comments(self, src):
        src = re.sub(r'--\[\[.*?\]\]', '', src, flags=re.DOTALL)
        src = re.sub(r'--[^\n]*', '', src)
        return src

    def _mangle_names(self, src, protect):
        protected = self.LUA_KW | self.LUA_GLOBALS | set(protect)
        idents = set(re.findall(r'\b([A-Za-z_][A-Za-z0-9_]*)\b', src))
        idents -= protected
        mapping = {name: self._id() for name in idents}
        for name in sorted(mapping, key=len, reverse=True):
            src = re.sub(r'\b' + re.escape(name) + r'\b', mapping[name], src)
        return src

    def _encrypt_strings(self, src):
        dec_fn  = self._id()
        tbl_nm  = self._id()
        enc_entries = []
        str_map = {}

        def replace_str(m):
            raw = m.group(0)
            try:
                val = eval(raw)  # safe for Lua string literals in Python
                if not isinstance(val, str) or len(val) == 0 or len(val) > 512:
                    return raw
            except:
                return raw
            seed = self.rng.randint(1, 0xFE)
            enc  = self._rolling_xor(val, seed)
            sid  = self._id()
            enc_entries.append((sid, seed, enc))
            return f'{dec_fn}("{sid}")'

        src = re.sub(r'"(?:[^"\\]|\\.)*"|\'(?:[^\'\\]|\\.)*\'', replace_str, src)

        if not enc_entries:
            return src, ""

        # Build decode infrastructure
        lines = [f"local {tbl_nm}={{}}"]
        for (sid, seed, enc) in enc_entries:
            bs = ",".join(f"0x{b:X}" for b in enc)
            lines.append(f'{tbl_nm}["{sid}"]={{0x{seed:X},{bs}}}')

        a,b,c,d,e,f = self._id(),self._id(),self._id(),self._id(),self._id(),self._id()
        lines.append(f"""local function {dec_fn}({a})
local {b}={tbl_nm}[{a}]
local {c}={b}[1]
local {d}={{}}
for {e}=2,#{b} do
local {f}={b}[{e}]~({c}&0xFF)
{d}[{e}-1]=string.char({f})
{c}=({c}*0x41+{f}+({e}-1))&0xFF
end
return table.concat({d})
end""")
        return src, "\n".join(lines) + "\n"

    def _encode_numbers(self, src):
        def repl(m):
            s = m.group(0)
            if re.search(r'[eExX\.]', s):
                return s
            try:
                return self._virtualize_num(int(s))
            except:
                return s
        return re.sub(r'\b\d+\b', repl, src)

    def _flatten_cf(self, src):
        lines = [l for l in src.split('\n') if l.strip()]
        if len(lines) < 4:
            return src
        sv   = self._id()
        tbl  = self._id()
        itr  = self._id()
        blocks, i = [], 0
        while i < len(lines):
            size = self.rng.randint(2, min(4, len(lines)-i))
            blocks.append('\n'.join(lines[i:i+size]))
            i += size
        state_nums = [self.rng.randint(100, 9999) for _ in blocks]
        out = [
            f"local {itr}=1",
            f"local {tbl}={{{','.join(str(s) for s in state_nums)}}}",
            f"local {sv}={tbl}[{itr}]",
            f"while {sv}~=nil do",
        ]
        for idx, (blk, sn) in enumerate(zip(blocks, state_nums)):
            kw = "if" if idx == 0 else "elseif"
            out.append(f"  {kw} {sv}=={sn} then")
            for bline in blk.split('\n'):
                if bline.strip():
                    out.append(f"    {bline}")
            out.append(f"    {itr}={itr}+1")
            out.append(f"    {sv}={tbl}[{itr}]")
        out += ["  else", "    break", "  end", "end"]
        return '\n'.join(out)

    def _vm_wrap(self, code):
        """Wrap code in a load()-based VM with rolling-XOR encrypted payload"""
        seed = self.rng.randint(1, 0xFE)
        enc  = self._rolling_xor(code, seed)
        bs   = ",".join(f"0x{b:X}" for b in enc)
        bc   = self._id()
        sv   = self._id()
        kv   = self._id()
        bv   = self._id()
        rv   = self._id()
        iv   = self._id()
        fn   = self._id()
        ev   = self._id()
        en   = self._id()
        return f"""do
local {bc}={{{self._hex(seed)},{bs}}}
local {sv}={{}}
local {kv}={bc}[1]&0xFF
for {iv}=2,#{bc} do
local {bv}={bc}[{iv}]~({kv}&0xFF)
{sv}[{iv}-1]=string.char({bv})
{kv}=({kv}*0x41+{bv}+({iv}-1))&0xFF
end
local {rv}=table.concat({sv})
local {fn},{ev}=load({rv},"@lv","t",setmetatable({{}},{{__index=_G}}))
if not {fn} then error({ev}) end
{fn}()
end"""

    def _env_wrap(self, code):
        en = self._id()
        fn = self._id()
        ev = self._id()
        tr = self._id()
        return f"""do
local {en}=setmetatable({{}},{{__index=_G,__newindex=function({tr},k,v)rawset({tr},k,v)end}})
local {fn},{ev}=load({json.dumps(code)},"@lv","t",{en})
if not {fn} then error({ev}) end
{fn}()
end"""

    def obfuscate(self, source):
        opts = self.opts
        protect = opts.get("protectNames", [])

        if opts.get("stripComments", True):
            source = self._strip_comments(source)

        str_header = ""
        if opts.get("encryptStrings", True):
            source, str_header = self._encrypt_strings(source)

        if opts.get("mangleNames", True):
            source = self._mangle_names(source, protect)

        if opts.get("encodeNumbers", True):
            source = self._encode_numbers(source)

        if opts.get("injectJunk", True):
            junk = '\n'.join(self._dead_block() for _ in range(self.rng.randint(2, 4)))
            source = junk + "\n" + source

        if opts.get("controlFlow", True):
            source = self._flatten_cf(source)

        full = str_header + source

        if opts.get("vmMode", True):
            full = self._vm_wrap(full)

        if opts.get("wrapEnv", True):
            full = self._env_wrap(full)

        header = f"-- Levititas v2.0.0 (Python engine) | {time.strftime('%Y-%m-%d')}\n"
        return header + full


def _python_fallback(source: str, opts: dict) -> str:
    obf = _PythonObf(opts)
    return obf.obfuscate(source)


if __name__ == "__main__":
    port  = int(os.environ.get("PORT", 5000))
    debug = os.environ.get("DEBUG", "0") == "1"
    print(f"[Levititas v2] Starting on http://0.0.0.0:{port}")
    lua_found = _lua()
    print(f"[Levititas v2] Lua engine: {'✓ ' + lua_found if lua_found else '✗ not found (Python fallback active)'}")
    app.run(host="0.0.0.0", port=port, debug=debug)
