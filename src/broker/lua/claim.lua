local q = ARGV[1]
local worker = ARGV[2]
local now = tonumber(ARGV[3])
local lease = tonumber(ARGV[4])
local n = tonumber(ARGV[5])
local prefix = 'beanline:{' .. q .. '}'
local delayed = redis.call('ZRANGEBYSCORE', prefix .. ':delayed', '-inf', now, 'LIMIT', 0, n)
for _, id in ipairs(delayed) do
  local jk = prefix .. ':job:' .. id
  local st = redis.call('HGET', jk, 'status')
  if st == 'available' or st == 'scheduled' then
    redis.call('ZREM', prefix .. ':delayed', id)
    if st == 'scheduled' then
      redis.call('HSET', jk, 'status', 'available')
      redis.call('HINCRBY', prefix .. ':depth', 'scheduled', -1)
      redis.call('HINCRBY', prefix .. ':depth', 'available', 1)
    end
    redis.call('LPUSH', prefix .. ':ready:' .. redis.call('HGET', jk, 'priority'), id)
  end
end
local taken = {}
for prio = 0, 3 do
  while #taken < n do
    local id = redis.call('RPOP', prefix .. ':ready:' .. prio)
    if not id then break end
    local jk = prefix .. ':job:' .. id
    if redis.call('HGET', jk, 'status') == 'available' then
      local epoch = redis.call('HINCRBY', jk, 'epoch', 1)
      local attempts = redis.call('HINCRBY', jk, 'attempts', 1)
      redis.call('HSET', jk, 'status', 'running', 'worker', worker)
      redis.call('SET', prefix .. ':lease:' .. id, worker, 'PX', lease)
      redis.call('ZADD', prefix .. ':expires', now + lease, id)
      redis.call('HINCRBY', prefix .. ':depth', 'available', -1)
      redis.call('HINCRBY', prefix .. ':depth', 'running', 1)
      redis.call('RPUSH', prefix .. ':events:' .. id, cjson.encode({ type = 'claimed', epoch = epoch, worker = worker }))
      redis.call('LTRIM', prefix .. ':events:' .. id, -50, -1)
      table.insert(taken, {
        id,
        tostring(epoch),
        redis.call('HGET', jk, 'kind'),
        redis.call('HGET', jk, 'args'),
        tostring(attempts),
        redis.call('HGET', jk, 'max_attempts'),
        tostring(prio),
        redis.call('HGET', jk, 'run_at'),
        redis.call('HGET', jk, 'context') or '{}',
      })
    end
  end
end
return taken
