--- Adapted from https://gist.github.com/daurnimator/192dc5b210718dd129cfc1e5986df97b
local ce = require "cqueues.errno"
local new_headers = require "http.headers".new
local server = require "http.server"
local http_util = require "http.util"
local zlib = require "http.zlib"
local http_tls = require "http.tls"
local openssl_ssl = require "openssl.ssl"
local openssl_ctx = require "openssl.ssl.context"
local Pkey = require "openssl.pkey"
local Crt = require "openssl.x509"
local Chain = require"openssl.x509.chain"

local stderr = io.stderr
local write = io.write
local asserts = assert
local try = pcall
local setm = setmetatable
local to_s = tostring
local to_n = tonumber
local typ = type
local insert = table.insert

local openf = io.open
local date = os.date
local fmt = string.format
local query_args = http_util.query_args

local iiter = ipairs
local TEXT =  "text/plain; charset=UTF-8"

--luacheck: ignore 111
local _ENV = {}

-- required for TLS context creation.
local function alpn_select(ssl, protos, version)
    for _, proto in iiter(protos) do
        if proto == "h2" and (version == nil or version == 2) then
            -- HTTP2 only allows >= TLSv1.2
            -- allow override via version
            if ssl:getVersion() >= openssl_ssl.TLS1_2_VERSION or version == 2 then
                return proto
            end
        elseif (proto == "http/1.1" and (version == nil or version == 1.1))
            or (proto == "http/1.0" and (version == nil or version == 1.0)) then
            return proto
        end
    end
    return nil
end

-- takes a file of one of more PEM encoded certificates and splits them into a primary cert and a chain of intermediates.
local function decode_fullchain(crtfile, iscontent)
    local crttxt
    if iscontent then crttxt = crtfile else
        local crtf  = asserts(openf(crtfile, "r"))
        crttxt = crtf:read"a"
        crtf:close()
    end
    local crts, pos = {}, 1

    repeat
        local st, ed = crttxt:find("-----BEGIN CERTIFICATE-----", pos, true)
        if st then
            local st2, ed2 = crttxt:find("-----END CERTIFICATE-----", ed + 1, true)
            if st2 then
                insert(crts, crttxt:sub(st, ed2))
                pos = ed2+1
            end
        end
    until st == nil

    local chain = Chain.new()
    local primary = asserts(Crt.new(crts[1]))
    for i = 2, #crts do
        local crt = asserts(Crt.new(crts[i]))
        chain:add(crt)
    end
    return primary,chain
end

-- construct a openssl context using the user's crtfile and keyfile.
local function new_ctx(version, crtpath, keypath)
    local ctx = http_tls.new_server_context()
    if http_tls.has_alpn then
        ctx:setAlpnSelect(alpn_select, version)
    end
    if version == 2 then
        ctx:setOptions(openssl_ctx.OP_NO_TLSv1 + openssl_ctx.OP_NO_TLSv1_1)
    end
    local keyfile = asserts(openf(keypath, "r"))
    local primary,crt = decode_fullchain(crtpath)
    asserts(ctx:setPrivateKey(Pkey.new(keyfile:read"a")))
    asserts(ctx:setCertificate(primary))
    asserts(ctx:setCertificateChain(crt))
    keyfile:close()
    return ctx
end

-- construct a openssl context using the user's crtfile and keyfile.
local function new_ctxlit(options)
    local version = options.version or 1.1
    local ctx = http_tls.new_server_context()
    if http_tls.has_alpn then
        ctx:setAlpnSelect(alpn_select, version)
    end
    if version == 2 then
        ctx:setOptions(openssl_ctx.OP_NO_TLSv1 + openssl_ctx.OP_NO_TLSv1_1)
    end

    local primary,crt = decode_fullchain(options.crt, true)
    asserts(ctx:setPrivateKey(Pkey.new(options.pkey)))
    asserts(ctx:setCertificate(primary))
    asserts(ctx:setCertificateChain(crt))

    return ctx
end

local response_methods = {}
local response_mt = {
    __index = response_methods;
    __name = nil;
}

local function new_response(request_headers, stream)
    local headers = new_headers();
    headers:append(":status", "500")
    local _, peer = stream:peername()
    local fullpath = request_headers:get":path"
    local query, path, fragment = {} do
        local qmark = fullpath:find("?", 1, true)
        if qmark then
            path = fullpath:sub(1, qmark - 1)
            local qf = fullpath:sub(qmark + 1)
            local hash = qf:find("#", 1, true)
            local q
            if hash then q, fragment = qf:sub(1, hash - 1), qf:sub(hash)
            else q, fragment = qf, ""
            end

            for name, value in query_args(q) do
                query[name] = value
            end
        else
            path = fullpath
            fragment = ""
        end
    end
    return setm({
        request_headers = request_headers;
        stream = stream,
        peername = peer,
        path = path,
        query = query,
        fragment = fragment,
        method = request_headers:get":method",
        headers = headers,
        body = nil,
    }, response_mt)
end

function response_methods:combined_log()
    return fmt('%s - - [%s] "%s %s HTTP/%g" %s %d "%s" "%s"',
        self.peername or "-",
        date("%d/%b/%Y:%H:%M:%S %z"),
        self.request_headers:get(":method") or "",
        self.request_headers:get(":path") or "",
        self.stream.connection.version,
        self.headers:get(":status") or "",
        self.stream.stats_sent,
        self.request_headers:get("referer") or "-",
        self.request_headers:get("user-agent") or "-")
end

local function check_compressed(headers, raw)
    if headers:get"content-encoding" == "gzip"
    or headers:get"content-encoding" == "deflate"
    or headers:get"content-encoding" == "x-gzip" then
        return zlib.inflate()(raw, true)
    end
    return raw
end

function response_methods:get_body()
    return check_compressed(self.request_headers, self.stream:get_body_as_string())
end

function response_methods:set_body(body)
    self.body = body

    local length
    if typ(self.body) == "string" then
        length = #body
    end
    if length then
        self.headers:upsert("content-length", to_s(length))
    end
end

function response_methods:set_503()
    self.headers:upsert(":status", "503")
    self.headers:upsert("content-type", TEXT)
    self:set_body"Internal server error."
end

function response_methods:set_500()
    self.headers:upsert(":status", "500")
    self.headers:upsert("content-type", TEXT)
    self:set_body"Internal server error."
end

function response_methods:set_401(msg)
    self.headers:upsert(":status", "401")
    self.headers:upsert("content-type", TEXT)
    self:set_body(msg or "Unauthorized")
end

function response_methods:set_ok()
    self.headers:upsert(":status", "204")
end

function response_methods:set_ok_and_reply(body, content_type)
    self.headers:upsert(":status", "200")
    self:set_body(body)
    if content_type then  self.headers:upsert("content-type", content_type) end
end

function response_methods:set_code_and_reply(code, body, content_type)
    self.headers:upsert(":status", to_s(code))
    self:set_body(body)
    if content_type then  self.headers:upsert("content-type", content_type) end
end

function response_methods:redirect(code_location, location)
    local code = to_n(code_location)
    if code then
        code = (code <= 300 and code < 400) and to_s(code) or "302"
    else
        code = "302"
        location = code_location
    end

    self.headers:upsert(":status", code)
    self.headers:append("location", location)
    return self
end

local function default_onerror(_, ...)
    stderr:write('[err] ', fmt(...), "\n")
end

local function server_onerror(_, context, op, err, _)
    local msg = op .. " on " .. to_s(context) .. " failed"
    if err then
        msg = msg .. ": " .. to_s(err)
    end
    write("[err] ",msg, "\n")
end

local function default_log(response)
    write('[log] ', response:combined_log(), "\n")
end

local NO_ROUTES = "Please provide either a callback or mapping of callbacks to route requests."

function new(options, crtfile, keyfile)
    local onerror = options.onerror or default_onerror
    local log = options.log or default_log
    local routes = asserts(options.routes, NO_ROUTES)

    local pathed = typ(routes) == 'table'
    local server_name = options.server or "shs-http-server"
    options.server = nil

    options.tls = nil
    if options.version == nil then options.version = 1.1 end

    if crtfile then
        options.ctx = new_ctx(options.version, crtfile, keyfile)
        options.tls = true
    else
        if options.ctx then
            options.tls = true
        else
            options.tls = false
        end
    end

    local function onstream(_, stream)
        local req_headers, err, errno = stream:get_headers()
        if req_headers == nil then
            -- connection hit EOF before headers arrived
            stream:shutdown()
            if err ~= ce.EPIPE and errno ~= ce.ECONNRESET then
                onerror("header error: %s", to_s(err))
            end
            return
        end

        local resp = new_response(req_headers, stream)
        resp.headers:append("server", server_name)

        local ok,err2
        if pathed and routes[resp.path] then
            ok, err2 = try(routes[resp.path], resp)
        elseif pathed and routes['*'] then
            ok, err2 = try(routes['*'], resp)
        elseif pathed then
            resp:set_code_and_reply(404, "Not found.")
        else
            ok, err2 = try(routes, resp)
        end


        if stream.state ~= "closed" and stream.state ~= "half closed (local)" then
            if not ok then
                resp:set_500()
            end
            local send_body = resp.body and req_headers:get ":method" ~= "HEAD"
            resp.headers:upsert("date", http_util.imf_date())
            stream:write_headers(resp.headers, not send_body)
            if send_body then
                stream:write_chunk(resp.body, true)
            end
        end
        stream:shutdown()
        log(resp)
        if not ok then
            onerror("stream error: %s", to_s(err2))
        end
    end

    options.onstream = onstream
    options.onerror  = server_onerror

    local myserver = server.listen(options)

    return myserver
end

_ENV.diy_tls = new_ctxlit

return _ENV