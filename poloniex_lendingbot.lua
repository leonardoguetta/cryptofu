require 'config'
local publicapi   = require 'exchange.poloniex'
local make_log    = require 'tools.logger'
local make_retry  = require 'tools.retry'
local heartbeat   = require 'tools.heartbeat'
local sleep = require 'tools.sleep'
local seq   = require 'pl.seq'
local set   = require 'pl.set'


local make_clearlog = function (logname, beat)
  local logger = make_log (logname)
  return function (...)
    beat:clear ()
    return logger (...)
  end
end

local pulse   = heartbeat.newpulse (79)
local log     = make_clearlog ("LENDBOT", pulse)
local loginfo = make_clearlog ("INFO", pulse)
local keys    = apikeys.poloniex
local lendapi = publicapi.lendingapi (keys.key, keys.secret)
publicapi.lendingbook = make_retry (publicapi.lendingbook, 3, loginfo, "wantread", "closed", "timeout")
lendapi.authquery     = make_retry (lendapi.authquery, 7, loginfo, "wantread", "closed", "timeout")

local tosatoshi = function (v) return tostring(v * 1E8) * 1 end
local function markgaps (initial)
  local lastseen = tosatoshi (initial)
  local gapcount
  return function(v)
    local rate = tosatoshi (v.rate)

    -- difference between two consecutive rates is 1 satoshi apart
    -- reset gapcount back to 0 if more than 1 satoshi apart
    gapcount = ((rate - lastseen == 1) and gapcount or 0) + 1
    v.gap = gapcount
    lastseen = rate
    return v
  end
end

local function tounix_time (timestr)
  local time_pat = "([12]%d%d%d)%-([01]%d)%-([0-3]%d) ([012]%d):([0-5]%d):([0-5]%d)"
  local year, month, day, hr, minute, sec = timestr:match (time_pat)
  return os.time
    { year = year, month = month, day = day,
      hour = hr, min = minute, sec = sec }
end

local utc_now = function () return os.time (os.date '!*t') end -- UTC
local cancel_openoffers = function (context)
  local openoffers  = context.openoffers
  local r =
    seq (openoffers)
    :map (function (v)
            v.date = tounix_time (v.date)
            return v
          end)
    :filter  (function (v)
                return (utc_now () - v.date) > 180
              end)
    :foreach (function (v)
                log (("cancelling offer: #%s"):format (v.id))
                local r, errmsg = lendapi:canceloffer (v.id)
                log (errmsg or r.message)
                sleep (250)
              end)
end

local compute_weightedavg = function (lendingbook)
  assert (#lendingbook > 0)
  local volume = seq (lendingbook)
                  :sum (function (v)
                          return v.amount + 0
                        end)
  local sum = seq (lendingbook)
                :sum (function (v)
                        return v.rate * v.amount
                      end)

  return sum / volume
end

local lend_quantity = 2.0
local place_newoffers = function (context)
  if #context.openoffers > 0 then return end

  local newoffer_count = 5
  local seen = {}
  local log_weightedavg = false
  local lendingbook = context.lendingbook.offers
  local avgrate = compute_weightedavg (lendingbook)

  local r =
    seq (lendingbook)
    :filter (function () return context.balance > lend_quantity end)
    :map (markgaps (lendingbook[1].rate))
    :filter (function (v) return v.amount*1 > 3 end)
    :map (function (v)
            v.rate = tosatoshi (v.rate) - v.gap
            v.rate = tostring (v.rate / 1E8)
            v.gap = nil
            return v
          end)
    :filter  (function (v)
                local unique = not seen[v.rate]
                seen[v.rate] = true

                return unique
              end)
    :filter (function (v) return v.rate + 0 > avgrate * 0.995 end)
    :take (newoffer_count)
    :map (function (v)
            sleep (250)
            local offerstat, errmsg = lendapi:placeoffer ("BTC", v.rate, lend_quantity)
            if errmsg then return errmsg end

            assert (offerstat.success == 1)
            context.balance = context.balance - lend_quantity

            local status = "%s #%d, %.12g @%.6f%%"
            return status:format (offerstat.message,
                                  offerstat.orderID,
                                  lend_quantity,
                                  v.rate * 100)
          end)
    :foreach (function (status)
                log (status)
                log_weightedavg = true
              end)

  if log_weightedavg then
    log (("volume weighted average rate: %.6f%%"):format (avgrate * 100))
  end
end

local prev_activeid = set ()
local prev_activedetail
local function check_activeoffers (activeoffers)
  local curr_activedetail = {}
  local curr_activeid = set (seq (activeoffers)
                              :map (function (v)
                                      curr_activedetail[v.id] = v
                                      return v.id
                                    end)
                              :copy ())

  if prev_activeid == curr_activeid then return end

  local expired = set.values (prev_activeid - curr_activeid)
  seq (expired)
    :map (function (id) return assert (prev_activedetail[ id ]) end)
    :foreach (function (v)
                local status = "expired offer: #%s, %.12g @%.6f%%"
                log (status:format (v.id, v.amount, v.rate * 100))
              end)
  local filled = set.values (curr_activeid - prev_activeid)
  seq (filled)
    :map (function (id) return assert (curr_activedetail[ id ]) end)
    :foreach (function (v)
                local status = "filled offer: #%s, %.12g @%.6f%%"
                log (status:format (v.id, v.amount, v.rate * 100))
              end)

  prev_activeid = curr_activeid
  prev_activedetail = curr_activedetail
end

local function log_changes (strfmt)
  local val
  return function (curr_val)
    if val ~= curr_val then
      val = curr_val
      loginfo (strfmt:format (val))
    end
  end
end

local show_balance      = log_changes "loanable balance: %.8f"
local show_activecount  = log_changes "%d active loans"
local show_opencount    = log_changes "%d open offers"

local show_lendinginfo = function (context)
  show_balance (context.balance)
  show_activecount (#context.activeoffers)
  show_opencount (#context.openoffers)
end

local seconds = 1E3
local function just_now () return os.clock () * seconds end

local function app_loop (func, throttle_delay)
  local start, elapse
  repeat
    start = just_now ()
    func ()
    elapse = just_now () - start
    if throttle_delay > elapse then
      local sleep_delay = throttle_delay - elapse
      assert (0 < sleep_delay and sleep_delay <= throttle_delay,
              '0 < '.. sleep_delay .. ' <= ' .. throttle_delay)
      sleep (sleep_delay)
    end
    pulse:tick ()
  until false
end

local function delay (f, msec)
  local last_run = just_now ()
  return function (...)
    local now = just_now ()
    local elapse = now - last_run
    if elapse < msec then return end

    last_run = now
    return f (...)
  end
end

local function bot ()
  print "Poloniex Lending Bot"
  local lendingcontext = {}
  local relaxed, lively = 1, 2
  local state = lively
  local run_bot =
  {
    [relaxed] = delay (function ()
      local openoffers    = assert (lendapi:openoffers "BTC")
      local activeoffers  = assert (lendapi:activeoffers "BTC")
      local balance       = assert (lendapi:balance "BTC").BTC + 0

      check_activeoffers (activeoffers)
      show_balance (balance)
      show_activecount (#activeoffers)
      if #openoffers > 0 or balance > lend_quantity then
        state = lively
        log "looking alive!"
      end
    end, 10*seconds),

    [lively] = delay (function ()
      lendingcontext.lendingbook    = assert (publicapi:lendingbook "BTC")
      lendingcontext.openoffers     = assert (lendapi:openoffers "BTC")
      lendingcontext.activeoffers   = assert (lendapi:activeoffers "BTC")
      lendingcontext.balance        = assert (lendapi:balance "BTC").BTC + 0

      check_activeoffers (lendingcontext.activeoffers)
      show_lendinginfo (lendingcontext)
      if #lendingcontext.openoffers == 0 and lendingcontext.balance < lend_quantity then
        state = relaxed
        log "relaxing..."
        return
      end
      cancel_openoffers (lendingcontext)
      place_newoffers (lendingcontext)
    end, 3*seconds),
  }

  return function () run_bot[state] () end
end


local main = function () app_loop (bot(), 0.5*seconds) end
local status, errmsg = xpcall (main, debug.traceback)
local quit_bot = (not status and errmsg:match '.+:%d+: interrupted!')
log (quit_bot and "got quit signal!" or errmsg)

log 'quitting...'
