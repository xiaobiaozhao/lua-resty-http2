-- Copyright (C) Alex Zhang

package.path = "./lib/?.lua;;"

local http2 = require "resty.http2"

local arg = arg
local exit = os.exit
local error = error
local print = print
local pairs = pairs

local host = arg[1]
local port = tonumber(arg[2])

if not host or not port then
    error("invalid host or port")
end

local sock = ngx.socket.tcp()

local ok, err = sock:connect(host, port)
if not ok then
    print("failed to connect ", host, ":", port, ": ", err)
    exit(1)
end

local prepare_request = function()
    local headers = {
        [":authority"] = "tokers.com",
        [":method"] = "GET",
        [":path"] = "/index.html",
        ["accept-encoding"] = "gzip",
        ["user-agent"] = "example/client",
    }

    return headers
end

local on_headers_reach = function(ctx, headers)
    print("received HEADERS frame:")
    for k, v in pairs(headers) do
        print(k, ": ", v)
    end
end

local on_data_reach = function(ctx, data)
    print("received DATA frame:")
    print(data)
end

local opts = {
    ctx = sock,
    recv = sock.receive,
    send = sock.send,
    preread_size = 1024,
    max_concurrent_stream = 100,
    prepare_request = prepare_request,
    on_headers_reach = on_headers_reach,
    on_data_reach = on_data_reach,
}

local client, err = http2.new(opts)
if not client then
    print("failed to create HTTP/2 client: ", err)
    exit(1)
end

ngx.sleep(5)
