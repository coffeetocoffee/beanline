local q = ARGV[1]
local id = ARGV[2]
local epoch = ARGV[3]
local retryable = ARGV[4] == '1'
local retry_at = tonumber(ARGV[5])
local now = tonumber(ARGV[6])
local err = ARGV[7]
local prefix = 'beanline:{' .. q .. '}'
local jk = prefix .. ':job:' .. id
if redis.call('HGET', jk, 'epoch') ~= epoch then return 0 end
if redis.call('HGET', jk, 'status') ~= 'running' then return 0 end
local attempts = tonumber(redis.call('HGET', jk, 'attempts'))
local maxa = tonumber(redis.call('HGET', jk, 'max_attempts'))
redis.call('DEL', prefix .. ':lease:' .. id)
redis.call('ZREM', prefix .. ':expires', id)
redis.call('HINCRBY', prefix .. ':depth', 'running', -1)
local status
if retryable and attempts < maxa then
  status = 'available'
  redis.call('HSET', jk, 'status', 'available', 'run_at', tostring(retry_at))
  redis.call('ZADD', prefix .. ':delayed', retry_at, id)
  redis.call('HINCRBY', prefix .. ':depth', 'available', 1)
else
  status = 'dead'
  redis.call('HSET', jk, 'status', 'dead', 'run_at', tostring(now))
  redis.call('HINCRBY', prefix .. ':depth', 'dead', 1)
  local uniq = redis.call('HGET', jk, 'unique')
  if uniq and uniq ~= '' then
    local guard = prefix .. ':guard:' .. redis.call('HGET', jk, 'kind') .. ':' .. uniq
    if redis.call('GET', guard) == id then redis.call('DEL', guard) end
  end
end
local ev_type = 'attempt_failed'
if status == 'dead' then ev_type = 'dead' end
redis.call('RPUSH', prefix .. ':events:' .. id, cjson.encode({ type = ev_type, error = err, next_run_at = retry_at }))
redis.call('LTRIM', prefix .. ':events:' .. id, -50, -1)
return { status, tostring(retry_at), tostring(attempts) }
