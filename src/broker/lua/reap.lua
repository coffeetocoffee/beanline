local q = ARGV[1]
local now = tonumber(ARGV[2])
local n = tonumber(ARGV[3])
local prefix = 'beanline:{' .. q .. '}'
local reaped = 0
local expired = redis.call('ZRANGEBYSCORE', prefix .. ':expires', '-inf', now, 'LIMIT', 0, n)
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
      redis.call('ZADD', prefix .. ':expires', now + lease_ttl, id)
    end
  end
end
return reaped
