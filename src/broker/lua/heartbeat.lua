local q = ARGV[1]
local lease = tonumber(ARGV[2])
local now = tonumber(ARGV[3])
local prefix = 'beanline:{' .. q .. '}'
local extended = 0
local i = 4
while i + 1 <= #ARGV do
  local id = ARGV[i]
  local epoch = ARGV[i + 1]
  i = i + 2
  local jk = prefix .. ':job:' .. id
  if redis.call('HGET', jk, 'epoch') == epoch and redis.call('HGET', jk, 'status') == 'running' then
    if redis.call('PEXPIRE', prefix .. ':lease:' .. id, lease) == 1 then
      redis.call('ZADD', prefix .. ':expires', now + lease, id)
      extended = extended + 1
    end
  end
end
return extended
