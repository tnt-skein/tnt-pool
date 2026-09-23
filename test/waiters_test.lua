--- Тесты очереди ожидающих: порядок, побудки и уход из очереди.
---
--- Условная переменная подменена такой, которая считает побудки и ничего
--- не ждёт: проверяется не сон, а то, кого именно будят. Ошибка здесь
--- не видна ни одному гейту — очередь, будящая не того, всё равно кого-то
--- будит, и пул продолжает работать, просто самый терпеливый не получает
--- соединения никогда.

local t = require('luatest')

local g = t.group('tnt.pool.waiters')

local helper = dofile('test/helper.lua')

---@type any
local waiters

--- Условные переменные в порядке их выдачи очереди.
---@type any
local conds

--- Условная переменная, которая считает побудки и не спит.
---@return table
local function make_cond()
    local cond = { signals = 0, broadcasts = 0, waited = nil }

    function cond:wait(seconds)
        self.waited = seconds

        return self.signals > 0
    end

    function cond:signal()
        self.signals = self.signals + 1
    end

    function cond:broadcast()
        self.broadcasts = self.broadcasts + 1
    end

    table.insert(conds, cond)

    return cond
end

g.before_each(function()
    waiters = helper.load('tnt.pool.waiters')
    conds = {}
end)

g.after_each(function()
    helper.unload()
end)

--- Очередь из указанного числа ожидающих.
---@param count integer
---@return any queue
---@return table tickets
local function queue_of(count)
    local queue = waiters.new(make_cond)
    local tickets = {}

    for _ = 1, count do
        table.insert(tickets, queue:push())
    end

    return queue, tickets
end

g.test_fresh_queue_has_nobody_in_it = function()
    local queue = waiters.new(make_cond)

    t.assert_equals(queue:empty(), true)
    t.assert_equals(queue:count(), 0)
end

g.test_queue_with_a_single_waiter_is_not_empty = function()
    local queue, tickets = queue_of(1)

    t.assert_equals(queue:empty(), false)
    t.assert_equals(queue:count(), 1)
    t.assert_equals(queue:is_head(tickets[1]), true)
end

g.test_first_to_arrive_is_the_head = function()
    local queue, tickets = queue_of(2)

    t.assert_equals(queue:empty(), false)
    t.assert_equals(queue:count(), 2)
    t.assert_equals(queue:is_head(tickets[1]), true)
    t.assert_equals(queue:is_head(tickets[2]), false)
end

g.test_nobody_is_the_head_of_a_queue_he_never_joined = function()
    local queue = queue_of(1)

    t.assert_equals(queue:is_head(nil), false)
    t.assert_equals(queue:is_head({ cond = make_cond() }), false)
end

g.test_head_that_leaves_wakes_the_next_one = function()
    local queue, tickets = queue_of(3)

    t.assert_equals(queue:remove(tickets[1]), true)
    t.assert_equals(queue:count(), 2)

    -- Побудка могла достаться уходящему: унести её с собой значит оставить
    -- очередь спящей при свободном соединении.
    t.assert_equals(conds[2].signals, 1)
    t.assert_equals(conds[3].signals, 0)
end

g.test_waiter_who_leaves_from_the_middle_wakes_nobody = function()
    local queue, tickets = queue_of(3)

    t.assert_equals(queue:remove(tickets[2]), true)
    t.assert_equals(queue:count(), 2)
    t.assert_equals(conds[1].signals, 0)
    t.assert_equals(conds[3].signals, 0)
end

g.test_leaving_twice_changes_nothing = function()
    local queue, tickets = queue_of(2)

    t.assert_equals(queue:remove(tickets[2]), true)
    t.assert_equals(queue:remove(tickets[2]), false)
    t.assert_equals(queue:count(), 1)
end

g.test_removing_nobody_changes_nothing = function()
    local queue = queue_of(1)

    t.assert_equals(queue:remove(nil), false)
    t.assert_equals(queue:count(), 1)
    t.assert_equals(conds[1].signals, 0)
end

g.test_only_the_head_is_woken = function()
    local queue = queue_of(3)

    queue:wake_one()

    t.assert_equals(conds[1].signals, 1)
    t.assert_equals(conds[2].signals, 0)
    t.assert_equals(conds[3].signals, 0)
end

g.test_waking_an_empty_queue_is_harmless = function()
    local queue = waiters.new(make_cond)

    queue:wake_one()
    queue:wake_all()

    t.assert_equals(queue:count(), 0)
end

g.test_closing_pool_wakes_everybody = function()
    local queue = queue_of(3)

    queue:wake_all()

    for index = 1, 3 do
        t.assert_equals(conds[index].broadcasts, 1)
        t.assert_equals(conds[index].signals, 0)
    end
end

g.test_waiter_learns_that_he_was_woken = function()
    local _, tickets = queue_of(1)

    conds[1]:signal()

    local woken, err = waiters.wait_on(tickets[1], 3)

    t.assert_equals(woken, true)
    t.assert_equals(err, nil)
    t.assert_equals(conds[1].waited, 3)
end

g.test_waiter_learns_that_his_time_is_up = function()
    local _, tickets = queue_of(1)

    local woken, err = waiters.wait_on(tickets[1], 0.25)

    t.assert_equals(woken, false)
    t.assert_equals(err, nil)
    t.assert_equals(conds[1].waited, 0.25)
end

g.test_broken_wait_is_reported_instead_of_bringing_the_pool_down = function()
    local ticket = { cond = helper.broken_cond('файбер отменён')() }

    local woken, err = waiters.wait_on(ticket, 3)

    t.assert_equals(woken, false)
    t.assert_equals(err, 'файбер отменён')
end
