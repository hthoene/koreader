local CookieJar = require("cookiejar")
local http = require("socket.http")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local url = require("socket.url")
local util = require("util")

local OPDSClient = {}
OPDSClient.__index = OPDSClient

local redirect_codes = {
    [301] = true,
    [302] = true,
    [303] = true,
    [307] = true,
    [308] = true,
}

local default_ports = {
    http = 80,
    https = 443,
}

local function isIdempotentRequest(method)
    return method == nil or method == "GET" or method == "HEAD"
end

local function isSameOrigin(left, right)
    return left.scheme == right.scheme
        and left.host == right.host
        and (left.port or default_ports[left.scheme]) == (right.port or default_ports[right.scheme])
end

local function isHttpsDowngrade(from_url, to_url)
    return url.parse(from_url).scheme == "https" and url.parse(to_url).scheme == "http"
end

function OPDSClient:new(options)
    return setmetatable(options, self)
end

function OPDSClient:request(request)
    local request_url = request.url
    local original_headers = request.headers or {}
    local original_origin = url.parse(request_url)

    for _ = 1, 5 do
        local headers = {}
        for name, value in pairs(original_headers) do
            if name:lower() ~= "cookie" then headers[name] = value end
        end
        local cookies = self.cookie_jar:headerFor(request_url)
        if cookies then headers.Cookie = cookies end

        local request_origin = url.parse(request_url)
        local same_origin = isSameOrigin(request_origin, original_origin)
        local function makeRequest()
            return socket.skip(1, http.request {
                url = request_url,
                method = request.method,
                headers = headers,
                sink = request.sink,
                user = same_origin and request.username or nil,
                password = same_origin and request.password or nil,
                redirect = false,
                response_headers = function(response_code)
                    return redirect_codes[response_code]
                end,
            })
        end

        local code, response_headers, status = makeRequest()
        if code == socketutil.SSL_HANDSHAKE_CODE and isIdempotentRequest(request.method) then
            code, response_headers, status = makeRequest()
        end
        self.cookie_jar:store(request_url, response_headers)

        if not redirect_codes[code] or not response_headers or not response_headers.location then
            return code, response_headers, status
        end

        local redirected_url = url.absolute(request_url, response_headers.location)
        if isHttpsDowngrade(request_url, redirected_url) then
            return code, response_headers, status
        end
        request_url = redirected_url
    end

    return nil, nil, "Too many redirects"
end

--- Download a file (it's removed on failure, i.e. if the HTTP code is not 200).
-- @treturn int HTTP code (or nil)
-- @treturn table response headers
-- @treturn string HTTP status (or error message)
function OPDSClient:download(local_path, remote_url, username, password)
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local code, headers, status = self:request{
        url      = remote_url,
        headers  = {
            ["Accept-Encoding"] = "identity",
        },
        sink     = ltn12.sink.file(io.open(local_path, "wb")),
        username = username,
        password = password,
    }
    socketutil:reset_timeout()
    if code ~= 200 then
        util.removeFile(local_path)
    end
    return code, headers, status
end

--[[--
Download files, with the given cookies (so this can be run in a sub-process, c.f. `Worker.task`).

@tparam {table,...} items files to download (`{ file = local_path, url = remote_url, username = …, password = … }`)
@tparam table cookies cookies (from a `CookieJar`)
@treturn table the files successfully downloaded (`downloaded[local_path] = true`)
]]
function OPDSClient.downloadFiles(items, cookies)
    local cookie_jar = CookieJar:new()
    cookie_jar.cookies = cookies or {}
    local client = OPDSClient:new{ cookie_jar = cookie_jar }
    local downloaded = {}
    for _, item in ipairs(items) do
        if client:download(item.file, item.url, item.username, item.password) == 200 then
            downloaded[item.file] = true
        end
    end
    return downloaded
end

return OPDSClient
