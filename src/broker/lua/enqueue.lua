local q = ARGV[1]
local kind = ARGV[2]
local args = ARGV[3]
local prio = ARGV[4]
local run_at = tonumber(ARGV[5])
local maxa = ARGV[6]
local uniq = ARGV[7]
local dedup = ARGV[8]
local ctx = ARGV[9]
-- Get time from Redis server to avoid clock skew between workers
local time_obj = redis.call('TIME')
local now_ms = tonumber(time_obj[1]) * 1000 + math.floor(tonumber(time_obj[2]) / 1000)
local prefix = 'beanline:{' .. q .. '}'
local status = 'available'
if run_at > now_ms then status = 'scheduled' end
local id = redis.call('INCR', 'beanline:seq')
local jk = prefix .. ':job:' .. id
if dedup ~= '' then
  local dk = 'beanline:sched:' .. kind .. ':' .. dedup
  if redis.call('SET', dk, id, 'NX', 'EX', 172800) == false then
    return { 0, redis.call('GET', dk) }
  end
end
if uniq ~= '' then
  local guard = prefix .. ':guard:' .. kind .. ':' .. uniq
  if redis.call('SET', guard, id, 'NX', 'EX', 86400) == false then
    if dedup ~= '' then
      redis.call('DEL', 'beanline:sched:' .. kind .. ':' .. dedup)
    end
    return { 0, redis.call('GET', guard) }
  end
end
redis.call('HSET', jk,
  'queue', q, 'kind', kind, 'args', args, 'priority', prio,
  'status', status, 'attempts', '0', 'max_attempts', maxa, 'epoch', '0',
  'unique', uniq, 'dedup', dedup, 'run_at', tostring(run_at),
  'context', ctx, 'inserted_at', tostring(now_ms))
if status == 'available' then
  redis.call('LPUSH', prefix .. ':ready:' .. prio, id)
else
  redis.call('ZADD', prefix .. ':delayed', run_at, id)
end
redis.call('HINCRBY', prefix .. ':depth', status, 1)
redis.call('RPUSH', prefix .. ':events:' .. id, cjson.encode({ type = 'enqueued' }))
redis.call('LTRIM', prefix .. ':events:' .. id, -50, -1)
return { 1, id }