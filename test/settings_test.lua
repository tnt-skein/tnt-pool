--- Тесты настроек пула: умолчания и то, что отвергается сразу.
---
--- Ошибка настройки поднимается исключением, поэтому проверки ловят
--- не пару `nil, err`, а текст исключения: именно он попадётся на глаза
--- тому, кто ошибся, и потому проверяется дословно.

local t = require('luatest')

local g = t.group('tnt.pool.settings')

local helper = dofile('test/helper.lua')

---@type any
local settings

g.before_each(function()
    settings = helper.load('tnt.pool.settings')
end)

g.after_each(function()
    helper.unload()
end)

--- Настройки, дополненные обязательным `open`.
---@param opts table|nil
---@return table
local function checked(opts)
    local given = { open = function() end }

    for key, value in pairs(opts or {}) do
        given[key] = value
    end

    return settings.check(given)
end

--- Чем проверка настроек отказала. Место ошибки из текста убирается.
---@param opts table|nil
---@return string
local function refusal(opts)
    local ok, err = pcall(checked, opts)

    t.assert_equals(ok, false, 'настройки приняты, хотя приниматься не должны')

    return (tostring(err):gsub('^.-:%d+: ', ''))
end

g.test_defaults_are_filled_in = function()
    local given = checked()

    t.assert_equals(given.size, 8)
    t.assert_equals(given.wait_timeout, 5)
    t.assert_equals(given.idle_timeout, 60)
    t.assert_equals(given.max_lifetime, 1800)
    t.assert_equals(given.open_cooldown, 0.5)
    t.assert_equals(given.leak_timeout, 300)
    t.assert_equals(given.sweep_interval, 5)
    t.assert_equals(given.name, 'pool')
end

g.test_tools_that_were_not_given_stay_empty = function()
    local given = checked()

    t.assert_equals(given.close, nil)
    t.assert_equals(given.alive, nil)
    t.assert_equals(given.reset, nil)
end

g.test_given_values_win_over_defaults = function()
    local alive = function()
        return true
    end

    local given = checked({
        size = 3,
        wait_timeout = 0.25,
        idle_timeout = 0,
        max_lifetime = 0,
        open_cooldown = 0,
        leak_timeout = 0,
        sweep_interval = 0,
        name = 'postgres',
        alive = alive,
    })

    t.assert_equals(given.size, 3)
    t.assert_equals(given.wait_timeout, 0.25)
    t.assert_equals(given.idle_timeout, 0)
    t.assert_equals(given.max_lifetime, 0)
    t.assert_equals(given.open_cooldown, 0)
    t.assert_equals(given.leak_timeout, 0)
    t.assert_equals(given.sweep_interval, 0)
    t.assert_equals(given.name, 'postgres')
    t.assert_equals(given.alive, alive)
end

g.test_pool_without_open_is_refused = function()
    local ok, err = pcall(settings.check, {})

    t.assert_equals(ok, false)
    t.assert_str_contains(
        tostring(err),
        'настройки пула.open — функция или вызываемая таблица, а не nil'
    )
end

g.test_pool_without_any_settings_at_all_is_refused = function()
    local ok, err = pcall(settings.check)

    t.assert_equals(ok, false)
    t.assert_str_contains(
        tostring(err),
        'настройки пула.open — функция или вызываемая таблица, а не nil'
    )
end

g.test_settings_that_are_not_a_table_are_refused = function()
    local ok, err = pcall(settings.check, 'open')

    t.assert_equals(ok, false)
    t.assert_str_contains(tostring(err), 'настройки пула — таблица, а не строка')
end

g.test_misspelt_setting_is_refused_instead_of_being_lost = function()
    -- Опечатка в сроке не должна молча оставлять умолчание: пул вёл бы
    -- себя не так, как написано у вызывающего.
    t.assert_equals(
        refusal({ idle_timout = 5 }),
        'настройки пула: ключа «idle_timout» нет, есть ' .. helper.KNOWN_SETTINGS
    )
end

g.test_misspelt_open_is_named_before_the_missing_one = function()
    -- «ключа «opne» нет» говорит, что случилось; «open — функция, а не nil»
    -- отправил бы искать, куда пропала функция.
    local ok, err = pcall(settings.check, { opne = function() end })

    t.assert_equals(ok, false)
    t.assert_str_contains(
        tostring(err),
        'настройки пула: ключа «opne» нет, есть ' .. helper.KNOWN_SETTINGS
    )
end

g.test_misspelt_setting_is_named_before_a_bad_value = function()
    t.assert_equals(
        refusal({ size = 0, sweep = 1 }),
        'настройки пула: ключа «sweep» нет, есть ' .. helper.KNOWN_SETTINGS
    )
end

g.test_tool_that_cannot_be_called_is_refused = function()
    t.assert_equals(
        refusal({ close = 'закрой сам' }),
        'настройки пула.close — функция или вызываемая таблица, а не строка'
    )
end

g.test_callable_table_serves_as_a_tool = function()
    -- Двойник и средство с состоянием — обычно таблица с `__call`,
    -- и пул зовёт её так же, как функцию.
    local close = setmetatable({}, { __call = function() end })

    t.assert_is(checked({ close = close }).close, close)
end

g.test_setting_of_the_wrong_kind_is_refused = function()
    t.assert_equals(
        refusal({ size = 'восемь' }),
        'настройки пула.size — целое число, а не строка'
    )

    t.assert_equals(
        refusal({ wait_timeout = '5' }),
        'настройки пула.wait_timeout — число, а не строка'
    )

    t.assert_equals(refusal({ name = 42 }), 'настройки пула.name — строка, а не число')
end

g.test_checked_settings_pass_the_check_again = function()
    -- Общий пул заводится из уже проверенных настроек, и лишнего ключа
    -- в них быть не должно.
    local alive = function()
        return true
    end

    local once = checked({ alive = alive, size = 3, name = 'redis' })

    t.assert_equals(settings.check(once), once)
end

g.test_setting_that_is_not_even_equal_to_itself_is_refused = function()
    -- NaN: сравнения с ним ложны все сразу, и срок из него истекает
    -- то мгновенно, то никогда.
    t.assert_equals(
        refusal({ idle_timeout = 0 / 0 }),
        'настройки пула.idle_timeout — число, а не NaN'
    )
end

g.test_endless_setting_is_refused = function()
    t.assert_equals(
        refusal({ wait_timeout = math.huge }),
        'настройка wait_timeout не может быть бесконечной'
    )

    t.assert_equals(
        refusal({ max_lifetime = -math.huge }),
        'настройка max_lifetime не может быть бесконечной'
    )

    -- Бесконечный размер отвергает уже род: целым бесконечность не бывает.
    t.assert_equals(
        refusal({ size = math.huge }),
        'настройки пула.size — целое число, а не inf'
    )
end

g.test_setting_below_its_floor_is_refused = function()
    t.assert_equals(refusal({ size = 0 }), 'настройка size не может быть меньше 1')

    -- Отрицательный срок не «поменьше нуля», а бессмыслица: соединение,
    -- простоявшее минус минуту, не бывает, а вычитание такого срока
    -- сдвигает миг проверки в прошлое.
    for _, field in ipairs({
        'idle_timeout',
        'max_lifetime',
        'open_cooldown',
        'leak_timeout',
        'sweep_interval',
    }) do
        t.assert_equals(
            refusal({ [field] = -1 }),
            ('настройка %s не может быть меньше 0'):format(field)
        )
    end
end

g.test_fractional_size_is_refused = function()
    t.assert_equals(refusal({ size = 2.5 }), 'настройки пула.size — целое число, а не 2.5')
end

g.test_size_of_one_is_allowed = function()
    t.assert_equals(checked({ size = 1 }).size, 1)
end

g.test_wait_without_a_deadline_is_refused = function()
    t.assert_equals(
        refusal({ wait_timeout = 0 }),
        'срок ожидания обязателен: без него ждут навсегда'
    )
end

g.test_deadline_is_checked_the_same_way_when_it_comes_with_a_call = function()
    t.assert_equals(settings.wait_of(nil, 7), 7)
    t.assert_equals(settings.wait_of(2, 7), 2)

    local ok, err = pcall(settings.wait_of, -1, 7)

    t.assert_equals(ok, false)
    t.assert_str_contains(tostring(err), 'настройка wait_timeout не может быть меньше 0')
end

g.test_deadline_that_comes_with_a_call_must_be_a_number = function()
    -- Срок вызова описания не проходит: род у него проверяет сам разбор.
    for _, span in ipairs({ 'пять', 0 / 0 }) do
        local ok, err = pcall(settings.wait_of, span, 7)

        t.assert_equals(ok, false)
        t.assert_str_contains(tostring(err), 'настройка wait_timeout должна быть числом')
    end
end
