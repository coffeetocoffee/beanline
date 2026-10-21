local q = ARGV[1]
local kind = ARGV[2]
local args = ARGV[3]
local prio = ARGV[4]
local run_at = tonumber(ARGV[5])
local maxa = ARGV[6]
local uniq = ARGV[7]
local dedup = ARGV[8]
-- Get time from Redis server to avoid clock skew between workers
local time_obj = redis.call('TIME')
local now_ms = tonumber(time_obj[1]) * 1000 + math.floor(tonumber(time_obj[2]) / 1000)
local prefix = 'beanline:{' .. q .. '}'
local status = 'available'
if run_at > now_ms then status = 'scheduled' end
local id = redis.call('INCR', 'beanline:seq')
local jk = prefix .. ':job:' .. id

-- Compute TTL based on run_at so uniqueness/dedup guards persist until the
-- scheduled job runs, rather than expiring at fixed times from enqueue time.
-- Grace periods ensure the guard outlasts the job's execution.
local function compute_ttl(run_at_ms, now_ms, grace_sec)
    local diff_ms = run_at_ms - now_ms
    local ttl_sec
    if diff_ms > 0 then
        -- TTL = (run_at - now) + grace, in seconds; ensure at least 1s.
        ttl_sec = math.floor(diff_ms / 1000) + grace_sec
    else
        -- Job is due or past due; use grace from enqueue time.
        ttl_sec = grace_sec
    end
    -- Ensure integer TTL (Redis EX requires integer, not float like 172800.0)
    local ttl = math.max(ttl_sec, 1)
    -- Use string.format to get clean integer, then tonumber for numeric return
    return tonumber(string.format("%d", ttl))
end

if dedup ~= '' then
  local dk = 'beanline:sched:' .. kind .. ':' .. dedup
  local dedup_ttl = compute_ttl(run_at, now_ms, 172800) -- 48h default grace, extended from run_at
  if redis.call('SET', dk, id, 'NX', 'EX', dedup_ttl) == false then
    return { 0, redis.call('GET', dk) }
  end
end
if uniq ~= '' then
  local guard = prefix .. ':guard:' .. kind .. ':' .. uniq
  local guard_ttl = compute_ttl(run_at, now_ms, 86400) -- 24h default grace, extended from run_at
  if redis.call('SET', guard, id, 'NX', 'EX', guard_ttl) == false then
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
  'context', ARGV[9], 'inserted_at', tostring(now_ms))
if status == 'available' then
  redis.call('LPUSH', prefix .. ':ready:' .. prio, id)
else
  redis.call('ZADD', prefix .. ':delayed', run_at, id)
end
redis.call('HINCRBY', prefix .. ':depth', status, 1)
redis.call('RPUSH', prefix .. ':events:' .. id, cjson.encode({ type = 'enqueued' }))
redis.call('LTRIM', prefix .. ':events:' .. id, -50, -1)
return { 1, id }