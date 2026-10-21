local q = ARGV[1]
local worker = ARGV[2]
local now = tonumber(ARGV[3])
local lease = tonumber(ARGV[4])
local n = tonumber(ARGV[5])
local aging_interval = tonumber(ARGV[6])
local prefix = 'beanline:{' .. q .. '}'
if redis.call('EXISTS', prefix .. ':paused') == 1 then
  return {}
end
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

-- Find the best job across all priority levels using aging
-- effective_priority = priority - floor((now - inserted_at) / aging_interval)
local best_job = nil
local best_eff_prio = math.huge
local best_prio = -1

for prio = 0, 3 do
  local id = redis.call('LINDEX', prefix .. ':ready:' .. prio, -1) -- RPOP takes from tail, so check tail
  if id then
    local jk = prefix .. ':job:' .. id
    if redis.call('HGET', jk, 'status') == 'available' then
      local inserted_at = tonumber(redis.call('HGET', jk, 'inserted_at'))
      local wait_ms = now - inserted_at
      local age_credit = 0
      if aging_interval > 0 and wait_ms > 0 then
        age_credit = math.floor(wait_ms / aging_interval)
      end
      local base_prio = tonumber(redis.call('HGET', jk, 'priority'))
      local eff_prio = base_prio - age_credit
      if eff_prio < best_eff_prio then
        best_eff_prio = eff_prio
        best_job = id
        best_prio = prio
      end
    end
  end
end

local taken = {}
if best_job then
  local id = best_job
  local jk = prefix .. ':job:' .. id
  if redis.call('HGET', jk, 'status') == 'available' then
    redis.call('RPOP', prefix .. ':ready:' .. best_prio)
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
      tostring(best_prio),
      redis.call('HGET', jk, 'run_at'),
      redis.call('HGET', jk, 'context') or '{}',
    })
  end
end

-- If we claimed one and need more, continue with next best
while #taken < n do
  best_job = nil
  best_eff_prio = math.huge
  best_prio = -1
  for prio = 0, 3 do
    local id = redis.call('LINDEX', prefix .. ':ready:' .. prio, -1)
    if id then
      local jk = prefix .. ':job:' .. id
      if redis.call('HGET', jk, 'status') == 'available' then
        local inserted_at = tonumber(redis.call('HGET', jk, 'inserted_at'))
        local wait_ms = now - inserted_at
        local age_credit = 0
        if aging_interval > 0 and wait_ms > 0 then
          age_credit = math.floor(wait_ms / aging_interval)
        end
        local base_prio = tonumber(redis.call('HGET', jk, 'priority'))
        local eff_prio = base_prio - age_credit
        if eff_prio < best_eff_prio then
          best_eff_prio = eff_prio
          best_job = id
          best_prio = prio
        end
      end
    end
  end
  if not best_job then break end
  local id = best_job
  local jk = prefix .. ':job:' .. id
  if redis.call('HGET', jk, 'status') == 'available' then
    redis.call('RPOP', prefix .. ':ready:' .. best_prio)
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
      tostring(best_prio),
      redis.call('HGET', jk, 'run_at'),
      redis.call('HGET', jk, 'context') or '{}',
    })
  end
end
return taken
