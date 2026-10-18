local q = ARGV[1]
local id = ARGV[2]
local epoch = ARGV[3]
local now = tonumber(ARGV[4])
local prefix = 'beanline:{' .. q .. '}'
local jk = prefix .. ':job:' .. id
if redis.call('HGET', jk, 'epoch') ~= epoch then return 0 end
if redis.call('HGET', jk, 'status') ~= 'running' then return 0 end
redis.call('HSET', jk, 'status', 'completed', 'finished_at', tostring(now))
redis.call('DEL', prefix .. ':lease:' .. id)
redis.call('ZREM', prefix .. ':expires', id)
redis.call('HINCRBY', prefix .. ':depth', 'running', -1)
redis.call('HINCRBY', prefix .. ':depth', 'completed', 1)
local uniq = redis.call('HGET', jk, 'unique')
if uniq and uniq ~= '' then
  local guard = prefix .. ':guard:' .. redis.call('HGET', jk, 'kind') .. ':' .. uniq
  if redis.call('GET', guard) == id then redis.call('DEL', guard) end
end
redis.call('RPUSH', prefix .. ':events:' .. id, cjson.encode({ type = 'completed' }))
redis.call('LTRIM', prefix .. ':events:' .. id, -50, -1)
return 1
