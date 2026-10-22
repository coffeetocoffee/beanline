local q = ARGV[1]
local id = ARGV[2]
local now = tonumber(ARGV[3])
local prefix = 'beanline:{' .. q .. '}'
local jk = prefix .. ':job:' .. id
local st = redis.call('HGET', jk, 'status')
if not st then return 'notfound' end
if st == 'available' or st == 'scheduled' then
  redis.call('HSET', jk, 'status', 'cancelled', 'finished_at', tostring(now), 'dead_reason', 'cancelled')
  redis.call('HINCRBY', prefix .. ':depth', st, -1)
  redis.call('HINCRBY', prefix .. ':depth', 'cancelled', 1)
  redis.call('LREM', prefix .. ':ready:' .. redis.call('HGET', jk, 'priority'), 0, id)
  redis.call('ZREM', prefix .. ':delayed', id)
  local uniq = redis.call('HGET', jk, 'unique')
  if uniq and uniq ~= '' then
    local guard = prefix .. ':guard:' .. redis.call('HGET', jk, 'kind') .. ':' .. uniq
    if redis.call('GET', guard) == id then redis.call('DEL', guard) end
  end
  redis.call('RPUSH', prefix .. ':events:' .. id, cjson.encode({ type = 'cancelled' }))
  redis.call('LTRIM', prefix .. ':events:' .. id, -50, -1)
  return 'cancelled'
end
if st == 'running' and ARGV[4] and redis.call('HGET', jk, 'epoch') == ARGV[4] then
  redis.call('HSET', jk, 'status', 'cancelled', 'finished_at', tostring(now), 'dead_reason', 'cancelled')
  redis.call('ZREM', prefix .. ':expires', id)
  redis.call('HINCRBY', prefix .. ':depth', 'running', -1)
  redis.call('HINCRBY', prefix .. ':depth', 'cancelled', 1)
  local uniq = redis.call('HGET', jk, 'unique')
  if uniq and uniq ~= '' then
    local guard = prefix .. ':guard:' .. redis.call('HGET', jk, 'kind') .. ':' .. uniq
    if redis.call('GET', guard) == id then redis.call('DEL', guard) end
  end
  redis.call('RPUSH', prefix .. ':events:' .. id, cjson.encode({ type = 'cancelled' }))
  redis.call('LTRIM', prefix .. ':events:' .. id, -50, -1)
  return 'cancelled'
end
return 'other'
