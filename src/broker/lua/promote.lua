local q = ARGV[1]
local now = tonumber(ARGV[2])
local n = tonumber(ARGV[3])
local prefix = 'beanline:{' .. q .. '}'
local moved = 0
local due = redis.call('ZRANGEBYSCORE', prefix .. ':delayed', '-inf', now, 'LIMIT', 0, n)
for _, id in ipairs(due) do
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
    moved = moved + 1
  else
    redis.call('ZREM', prefix .. ':delayed', id)
  end
end
return moved
