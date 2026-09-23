--- Тесты учёта отказов открытия: пауза, её рост и приговор отказу.
---
--- Часов здесь нет вовсе: миг отказа приходит аргументом, и проверка задаёт
--- его сама. Поэтому границы — «ровно в миг конца паузы» и «на миг
--- раньше» — проверяются точно, без двойника часов.

local t = require('luatest')

local g = t.group('tnt.pool.opening')

--- Ошибки Tarantool: ими `open` тоже вправе отказать. Конструктор
--- в аннотациях описан не полностью, поэтому берётся через ссылку без типа.
---@type any
local box_error = box.error

local helper = dofile('test/helper.lua')

---@type any
local opening

g.before_each(function()
    opening = helper.load('tnt.pool.opening')
end)

g.after_each(function()
    helper.unload()
end)

--- Учёт, в котором уже случились названные отказы, все в миг 100.
---@param cooldown number
---@param ... any Отказы по порядку
---@return any
local function failed_with(cooldown, ...)
    local record = opening.new(cooldown)

    for index = 1, select('#', ...) do
        record:failed((select(index, ...)), 100)
    end

    return record
end

--- Отказ-таблица, которая читается строкой.
---@param message string
---@param retriable any
---@return table
local function refusal(message, retriable)
    return setmetatable({ message = message, retriable = retriable }, {
        __tostring = function(self)
            return self.message
        end,
    })
end

g.test_fresh_record_lets_open_at_any_moment = function()
    local record = opening.new(0.5)

    t.assert_equals(record.streak, 0)
    t.assert_equals(record.final, nil)
    t.assert_equals(record.last_error, nil)
    t.assert_equals(record:allows(0), true)
    t.assert_equals(record:allows(-5), true)
    t.assert_equals(record:sleep_span(100, 105), 5)
end

g.test_refusal_is_written_down_with_its_reason = function()
    local record = failed_with(0.5, 'служба не отвечает')

    t.assert_equals(record.streak, 1)
    t.assert_equals(
        record.last_error,
        'открыть соединение не удалось: служба не отвечает'
    )
    t.assert_equals(record.blocked_until, 100.5)
    t.assert_equals(record.final, nil)
end

g.test_refusal_without_a_reason_says_so = function()
    local record = failed_with(0.5, nil)

    t.assert_equals(
        record.last_error,
        'открыть соединение не удалось: причина не названа'
    )
end

g.test_pause_doubles_with_every_refusal_in_a_row = function()
    local record = opening.new(0.5)
    local pauses = {}

    for _ = 1, 4 do
        record:failed('нет', 100)
        table.insert(pauses, record.blocked_until - 100)
    end

    t.assert_equals(pauses, { 0.5, 1, 2, 4 })
    t.assert_equals(record.streak, 4)
end

g.test_pause_stops_growing_at_half_a_minute = function()
    local record = failed_with(20, 'нет')

    t.assert_equals(record.blocked_until, 120)

    record:failed('нет', 100)

    t.assert_equals(record.blocked_until, 130)
end

g.test_zero_cooldown_lets_open_again_the_same_moment = function()
    local record = failed_with(0, 'нет')

    t.assert_equals(record.blocked_until, 100)
    t.assert_equals(record:allows(100), true)
end

g.test_pause_holds_until_its_last_moment = function()
    local record = failed_with(0.5, 'нет')

    t.assert_equals(record:allows(100.499), false)
    t.assert_equals(record:allows(100.5), true)
    t.assert_equals(record:allows(101), true)
end

g.test_sleep_ends_when_the_pause_does = function()
    local record = failed_with(0.5, 'нет')

    t.assert_equals(record:sleep_span(100.25, 105), 0.25)
end

g.test_sleep_never_passes_the_deadline = function()
    local record = failed_with(20, 'нет')

    t.assert_equals(record:sleep_span(101, 104), 3)
end

g.test_pause_that_is_over_does_not_shorten_the_sleep = function()
    local record = failed_with(0.5, 'нет')

    -- Пауза кончилась ровно сейчас, а открыть ждущему не дадут: он
    -- не первый в очереди или места в пуле нет. Спать до конца паузы
    -- значило бы не спать вовсе и крутить цикл до срока.
    t.assert_equals(record:sleep_span(100.5, 103), 2.5)
    t.assert_equals(record:sleep_span(102, 103), 1)
    t.assert_equals(record:sleep_span(102, 103, false), 1)
end

g.test_pause_that_is_over_is_not_slept_by_the_one_who_may_open = function()
    local record = failed_with(0.5, 'нет')

    -- Первому в очереди с местом в пуле мешала только пауза, и раз она
    -- вышла, спать ему нечего: он пробует сразу.
    t.assert_equals(record:sleep_span(100.75, 105, true), 0)
    t.assert_equals(record:sleep_span(100.5, 105, true), 0)

    -- Пока пауза идёт, он спит до её конца, как и все.
    t.assert_equals(record:sleep_span(100.25, 105, true), 0.25)
end

g.test_zero_pause_waits_for_a_wakeup_even_for_the_one_who_may_open = function()
    local record = failed_with(0, 'нет')

    -- Пауза в ноль — «пробовать на следующей побудке»: без неё первый
    -- в очереди пробовал бы открыть без передышки до конца срока.
    t.assert_equals(record:sleep_span(100, 105, true), 5)
end

g.test_refusal_marked_as_final_is_kept_as_it_is = function()
    local given = refusal('пароль неверен', false)
    local record = failed_with(0.5, given)

    t.assert_is(record.final, given)
    t.assert_equals(
        record.last_error,
        'открыть соединение не удалось: пароль неверен'
    )
end

g.test_box_error_can_be_final_too = function()
    local given = box_error.new({ reason = 'нет такой базы', retriable = false })
    local record = failed_with(0.5, given)

    t.assert_is(record.final, given)
    t.assert_equals(
        record.last_error,
        'открыть соединение не удалось: нет такой базы'
    )
end

g.test_only_an_explicit_false_makes_a_refusal_final = function()
    -- Отказ без слова — временный: служба, моргнувшая на полсекунды,
    -- иначе уронила бы все запросы разом.
    local unreadable = setmetatable({}, {
        __index = function()
            error('поле не читается')
        end,
    })

    local cases = {
        { name = 'строка', err = 'пароль неверен' },
        { name = 'пусто', err = nil },
        { name = 'число', err = 5 },
        { name = 'можно повторить', err = refusal('нет связи', true) },
        { name = 'без слова', err = refusal('нет связи', nil) },
        { name = 'ноль, а не false', err = refusal('нет связи', 0) },
        { name = 'поле бросает', err = unreadable },
        { name = 'box.error без слова', err = box_error.new({ reason = 'нет связи' }) },
    }

    for _, case in ipairs(cases) do
        local record = failed_with(0.5, case.err)

        t.assert_equals(record.final, nil, case.name)
        t.assert_equals(record.streak, 1, case.name)
    end
end

g.test_later_refusal_decides_whether_it_is_final = function()
    local record = failed_with(0.5, refusal('пароль неверен', false), 'нет связи')

    t.assert_equals(record.final, nil)
    t.assert_equals(record.last_error, 'открыть соединение не удалось: нет связи')
end

g.test_success_starts_the_count_over = function()
    local record = failed_with(0.5, 'нет', refusal('пароль неверен', false))

    record:succeeded()

    t.assert_equals(record.streak, 0)
    t.assert_equals(record.final, nil)

    -- Пауза и текст остаются: паузу назначил соседний отказ, а текст —
    -- след для stats.
    t.assert_equals(record.blocked_until, 101)
    t.assert_equals(
        record.last_error,
        'открыть соединение не удалось: пароль неверен'
    )

    record:failed('нет', 200)

    t.assert_equals(record.blocked_until, 200.5)
end
