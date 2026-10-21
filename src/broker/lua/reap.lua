local q = ARGV[1]
-- Get time from Redis server to avoid clock skew between workers
local time_obj = redis.call('TIME')
local now_ms = tonumber(time_obj[1]) * 1000 + math.floor(tonumber(time_obj[2]) / 1000)
local n = tonumber(ARGV[2])
local prefix = 'beanline:{' .. q .. '}'
local reaped = 0
local expired = redis.call('ZRANGEBYSCORE', prefix .. ':expires', '-inf', now_ms, 'LIMIT', 0, n)
for _, id in ipairs(expired) do
  local lease_alive = redis.call('EXISTS', prefix .. ':lease:' .. id)
  if lease_alive == 0 then
    local jk = prefix .. ':job:' .. id
    if redis.call('HGET', jk, 'status') == 'running' then
      redis.call('ZREM', prefix .. ':expires', id)
      local attempts = tonumber(redis.call('HGET', jk, 'attempts'))
      local maxa = tonumber(redis.call('HGET', jk, 'max_attempts'))
      redis.call('HINCRBY', prefix .. ':depth', 'running', -1)
      if attempts >= maxa then
        redis.call('HSET', jk, 'status', 'dead')
        redis.call('HINCRBY', prefix .. ':depth', 'dead', 1)
        local uniq = redis.call('HGET', jk, 'unique')
        if uniq and uniq ~= '' then
            local guard = prefix .. ':guard:' .. redis.call('HGET', jk, 'kind') .. ':' .. uniq
            if redis.call('GET', guard) == id then redis.call('DEL', guard) end
        end
      else
        redis.call('HINCRBY', jk, 'attempts', -1)
        redis.call('HSET', jk, 'status', 'available')
        redis.call('LPUSH', prefix .. ':ready:' .. redis.call('HGET', jk, 'priority'), id)
        redis.call('HINCRBY', prefix .. ':depth', 'available', 1)
      end
      redis.call('RPUSH', prefix .. ':events:' .. id, cjson.encode({ type = 'reaped', attempts = attempts }))
      redis.call('LTRIM', prefix .. ':events:' .. id, -50, -1)
      reaped = reaped + 1
    else
      redis.call('ZREM', prefix .. ':expires', id)
    end
  else
    redis.call('ZREM', prefix .. ':expires', id)
    local lease_ttl = redis.call('PTTL', prefix .. ':lease:' .. id)
    if lease_ttl > 0 then
      redis.call('ZADD', prefix .. ':expires', now_ms + lease_ttl, id)
    end
  end
end
return reaped