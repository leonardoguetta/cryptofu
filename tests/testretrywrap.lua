require 'pl.app'.require_here ".."
local make_retry = require 'tools.retry'
local utest = require 'tools.unittest'

local function echo_off(func, ...)
  local stdout_mt = getmetatable (io.stdout).__index
  local stdout_write = stdout_mt.write
  stdout_mt.write = function () end
  func (...)
  stdout_mt.write = stdout_write
end

utest.group "retrywrap"
{
  test_retryfunc = function ()
    local retry_count = 0
    local f = function ()
      retry_count = retry_count + 1
      return (assert (retry_count == 2, "some error"))
    end
    
    local f_wrapped = make_retry (f, 2, "some error")
    echo_off (f_wrapped)
    assert (retry_count == 2)
  end,

  test_retrylogfunc = function ()
    local retry_count = 0
    local f = function ()
      retry_count = retry_count + 1
      error "an error\n"
    end
    local logged_str = {}
    local logger = function (...)
      local n = select ('#', ...)
      for i = 1, n do
        table.insert (logged_str, select (i, ...))
      end
    end
    local f_wrapped = make_retry (f, 2, logger, "an error\n")
    pcall (f_wrapped)
    local expected = "an error\n" ..
                     "an error\n" ..
                     "retry fails after 2 attempt(s)."
    assert (retry_count == 2)
    logged_str = table.concat (logged_str)
    assert (logged_str == expected, logged_str)
  end,

  test_retrytable = function ()
    local r1, r2 = 0, 0
    local t =
    {
      func1 = function () r1 = r1 + 1; assert (r1 == 2, "an error") end,
      func2 = function () r2 = r2 + 1; assert (r2 == 2, "an error") end,
    }

    local t_wrapped = make_retry (t, 2, "an error")
    echo_off (t_wrapped.func1)
    echo_off (t_wrapped.func2)
    assert (r1 == 2)
    assert (r2 == 2)
  end,

  test_retrystackoverflow = function ()
    local count = 0
    local mt = {}
    mt.__index = function (t, k)
      if k == "badcall" then count = count + 1 end
      return nil
    end
    local t = setmetatable({}, mt)
    t.goodcall = function () count = count + 1 end

    local t_wrapped = make_retry (t, 2, "an error")
    assert  (not pcall (function () t_wrapped.goodcall(); t_wrapped.badcall() end))
    assert (count == 2)
  end,

  test_retrymultireason = function ()
    local r = 0
    local t =
    {
      func = function ()
        local errlist = { "error1", "error2" }
        r = r + 1
        assert (r == 3, errlist[r])
      end,
    }

    local t_wrapped = make_retry (t, 3, "error1", "error2")
    echo_off (t_wrapped.func)
    assert (r == 3)
  end,

  test_retrynestedexhaust = function ()
    local r = 0
    local t = 
    { 
      func1 = function (self) self.func2() end,
      func2 = function () r = r + 1; error "some error" end
    }
    local t_wrapped = make_retry (t, 3, "some error")
    local noerr, errmsg = echo_off (pcall, t_wrapped.func1, t_wrapped)
    assert (not noerr)
    assert (r == 3, r)
  end,
}

utest.run "retrywrap"
