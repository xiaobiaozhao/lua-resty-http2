-- Copyright Alex Zhang (tokers)

local util = require "resty.http2.util"
local hpack = require "resty.http2.hpack"
local h2_frame = require "resty.http2.frame"

local new_tab = util.new_tab
local clear_tab = util.clear_tab
local children_update
local pairs = pairs
local is_num = util.is_num
local is_tab = util.is_tab
local lower = string.lower
local concat = table.concat

local frag
local frag_len = 0

local STATE_IDLE = 0
local STATE_OPEN = 1
local STATE_CLOSED = 3
local STATE_HALF_CLOSED_LOCAL = 4
local STATE_HALF_CLOSED_REMOTE = 5
local STATE_RESERVED_LOCAL = 6
local STATE_RESERVED_REMOTE = 7

local _M = {
    _VERSION = "0.1",

    MAX_WEIGHT = 256,
    DEFAULT_WEIGHT = 16,
}

local IS_CONNECTION_SPEC_HEADERS = {
    ["connection"] = true,
    ["keep-alive"] = true,
    ["proxy-connection"] = true,
    ["upgrade"] = true,
    ["transfer-encoding"] = true,
}


children_update = function(node)
    if not node then
        return
    end

    local child = node.child
    if not child then
        return
    end

    local max_weight = _M.MAX_WEIGHT
    local rank = node.rank
    local rel_weight = node.rel_weight

    while true do
        child.rank = rank + 1
        child.rel_weight = rel_weight / max_weight * child.weight

        children_update(child)

        child = child.next_sibling
    end
end


-- let depend as current stream's parent
function _M:set_dependency(depend, excl)
    local stream = self
    local root = stream.session.root

    if not depend then
        depend = root
        excl = false
    end

    local child
    local max_weight = _M.MAX_WEIGHT

    if depend == root then
        stream.rel_weight = stream.weight / max_weight
        stream.rank = 1
        child = depend.child

    else
        -- check whether stream is an ancestor of depend
        while true do
            local node = depend.parent
            if node == root or node.rank < stream.rank then
                break
            end

            if node == stream then
                -- firstly take depend out of it's "old parent"
                local last_node = depend.last_sibling
                local next_node = depend.next_sibling

                if last_node then
                    last_node.next_sibling = next_node
                end

                if next_node then
                    next_node.last_sibling = last_node
                end

                -- now stream.parent will be the "new parent" of depend
                local parent = stream.parent
                local first_child = parent.child

                first_child.last_sibling = depend
                depend.last_sibling = nil
                depend.next_sibling = first_child
                depend.parent = parent
                parent.child = depend

                if parent == root then
                    depend.rank = 1
                    depend.rel_weight = depend.weight / max_weight
                else
                    local weight = depend.weight
                    depend.rank = parent.rank + 1
                    depend.rel_weight = parent.rel_weight / max_weight * weight
                end

                if not excl then
                    children_update(depend)
                end

                break
            end
        end

        stream.rank = depend.rank + 1
        stream.rel_weight = depend.rel_weight / max_weight * stream.weight
        child = depend.child
    end

    if excl and child then
        -- stream should be the sole direct child of depend
        local c = child
        local last

        while true do
            c.parent = stream
            if not c.next_sibling then
                last = c -- the last sibling
                break
            end

            c = c.next_sibling
        end

        last.next_sibling = stream.child
        stream.child.last_sibling = last

        stream.child = child
        depend.child = stream
    end

    local last_node = stream.last_sibling
    local next_node = stream.next_sibling

    if last_node then
        last_node.next_sibling = next_node
    end

    if next_node then
        next_node.last_sibling = last_node
    end

    stream.parent = depend

    children_update(stream)
end


-- serialize headers and create a headers frame,
-- note this function does not check the HTTP protocol semantics,
-- callers should check this in the higher land.
function _M:submit_headers(headers, end_stream, priority, pad)
    local state = self.state
    if state ~= STATE_IDLE
       and state ~= STATE_OPEN
       and state ~= STATE_RESERVED_LOCAL
       and state ~= STATE_HALF_CLOSED_REMOTE
    then
        return nil, "invalid stream state"
    end

    local headers_count = #headers
    if frag_len < headers_count then
        frag = new_tab(headers_count, 0)
        frag_len = headers_count
    else
        clear_tab(frag)
    end

    for name, value in pairs(headers) do
        name = lower(name)
        if IS_CONNECTION_SPEC_HEADERS[name] then
            goto continue
        end

        local index = hpack.COMMON_REQUEST_HEADERS_INDEX[name]
        if is_num(index) then
            frag[#frag + 1] = hpack.incr_indexed(index)
            hpack.encode(value, frag, false)
            goto continue
        end

        if is_tab(index) then
            for v_name, v_index in pairs(index) do
                if value == v_name then
                    frag[#frag + 1] = hpack.indexed(v_index)
                    goto continue
                end
            end
        end

        hpack.encode(name, frag, true)
        hpack.encode(value, frag, true)

        ::continue::
    end

    local sid = self.sid

    frag = concat(frag)
    local frame, err = h2_frame.headers.new(frag, priority, pad, end_stream,
                                            sid)
    if not frame then
        return nil, err
    end

    self.session:frame_queue(frame)
end


function _M.new(sid, weight, session)
    if not session then
        return nil, "orphan stream is banned"
    end

    weight = weight or _M.DEFAULT_WEIGHT

    local stream = {
        sid = sid,
        state = _M.STATE_IDLE,
        data = new_tab(1, 0),
        parent = nil,
        next_sibling = nil,
        last_sibling = nil,
        child = nil, -- the first child
        weight = weight,
        rel_weight = -1,
        rank = -1,
        opaque_data = nil, -- user private data
        session = session, -- the session
        send_window = session.init_window,
        recv_window = session.preread_size,
    }

    return stream
end


function _M.new_root()
    local root = {
        sid = 0x0,
        rank = 0,
        child = nil,
        parent = nil,
    }

    root.parent = root

    return root
end


return _M
