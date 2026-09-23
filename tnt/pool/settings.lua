--- Настройки пула: умолчания и их проверка.
---
--- Проверка вынесена из самого пула и идёт целиком при заведении, а не
--- по крупице там, где до каждой настройки впервые дошло дело. Пул заводят
--- при старте узла, а первое соединение берут через час под нагрузкой —
--- опечатка в сроке ожидания обязана обнаружиться раньше, чем этот час
--- пройдёт, и обнаружиться в том месте, где её сделали.
---
--- Ошибка настройки поднимается исключением, а не возвращается парой
--- `nil, err`. Пара — для чужого сервера, который вправе отказать; строка
--- вместо числа в сроке — ошибка того, кто писал код, и проглотить её
--- значит получить пул, который ведёт себя не так, как написано в его
--- настройках, и никогда об этом не скажет.
---
--- Умолчания выбраны в пользу чужой службы, а не своего удобства: пул
--- меряется не желанием клиента, а тем, сколько одновременных запросов
--- переварит тот, к кому ходят.

local must = require('tnt.must')

local Module = {}

--- Уровень вины: строка того, кто завёл пул.
---
--- `check` зовут `pool.new` и `pool.configure`, оба не хвостовым вызовом:
--- уровень 2 — их строка в `pool.lua`, 3 — строка вызывающего. Опечатку
--- сделали там, и чинить её надо там же.
local OWNER = 3

--- Проверки аргументов с виной на строке того, кто завёл пул.
local owner = must.at(OWNER)

--- Как настройки называются в отказе.
local TITLE = 'настройки пула'

--- Описание настроек: незнакомый ключ — отказ, а не молчаливое умолчание.
---
--- Ради набора ключей оно и заведено. Опечатка в имени (`idle_timout`)
--- ничем иначе не отказывает: настройки с верным именем нет, и пул берёт
--- умолчание — ведёт себя не так, как написано у вызывающего, и никогда
--- об этом не скажет.
---
--- Значения здесь проверяются только родом. Границы проверяет разбор
--- ниже: те же проверки идут и по сроку, пришедшему с вызовом `take`,
--- а у того описания нет. Средство — любое вызываемое: пул зовёт его
--- через `pcall`, и таблице с `__call` это не мешает. Размер — целое
--- число: половины соединения не бывает.
local OPTIONS = {
    open = 'callable',
    close = '?callable',
    alive = '?callable',
    reset = '?callable',
    size = '?integer',
    idle_timeout = '?number',
    wait_timeout = '?number',
    max_lifetime = '?number',
    open_cooldown = '?number',
    leak_timeout = '?number',
    sweep_interval = '?number',
    name = '?string',
}

--- Сколько соединений держать.
---
--- Восемь: большой пул не ускоряет работу, а переносит очередь со своего
--- узла на чужой, где она уже никем не ограничена и не видна. Восьми
--- хватает, чтобы занять службу, и мало, чтобы её завалить.
Module.DEFAULT_SIZE = 8

--- Сколько соединению позволено простаивать.
---
--- Минута: держать открытым то, чем не пользуются, значит занимать чужой
--- сервер своим бездействием — предел соединений у него один на всех.
Module.DEFAULT_IDLE_TIMEOUT = 60

--- Сколько ждать свободного соединения.
---
--- Пять секунд: запрос, которому не хватило соединения за пять секунд,
--- упёрся не в пул, а в перегруз, и честный отказ здесь полезнее очереди,
--- растущей быстрее, чем она рассасывается.
Module.DEFAULT_WAIT_TIMEOUT = 5

--- Сколько соединению позволено жить с открытия.
---
--- Полчаса: на пути до службы стоят её собственный предел времени жизни,
--- балансировщик и межсетевой экран, и каждый из них однажды рвёт
--- соединение молча. Срок здесь обязан быть заметно короче самого
--- короткого из чужих — тогда пул переоткрывает соединение сам и заранее,
--- в спокойную минуту, а не узнаёт об обрыве в середине запроса.
Module.DEFAULT_MAX_LIFETIME = 1800

--- С какой паузы начинается остановка после отказа открытия.
---
--- Полсекунды: столько незаметно человеку и достаточно, чтобы сотня
--- файберов не превратилась в сотню попыток соединиться с упавшей службой.
Module.DEFAULT_OPEN_COOLDOWN = 0.5

--- Насколько пауза может вырасти.
---
--- Полминуты: дальше расти незачем — служба, не поднявшаяся за полминуты,
--- не поднимется и от более редких попыток, а узнать о её возвращении
--- хочется в те же полминуты.
Module.MAX_OPEN_COOLDOWN = 30

--- С какого срока удержания соединение считается утёкшим.
---
--- Пять минут: взявший и не вернувший не виден ничем — запросов соединение
--- не делает, пул считает его занятым, и заметить пропажу можно только
--- по тому, что через сутки пул перестал выдавать что-либо. Пять минут
--- длиннее любого запроса и короче суток, а цена ошибки — одна запись
--- в журнале: соединение не отнимается, его, возможно, и правда держат.
Module.DEFAULT_LEAK_TIMEOUT = 300

--- Как часто убирать простаивающие соединения.
---
--- Пять секунд: уборка не срочное дело, а такт чаще этого стоит дороже
--- того, что экономит.
Module.DEFAULT_SWEEP_INTERVAL = 5

--- Требует, чтобы настройка была числом не меньше названного предела.
---
--- Бесконечность отвергается наравне с отрицательным числом: срок, равный
--- бесконечности, выглядит как «подождать подольше», а означает «не ждать
--- никого никогда». Не-число, равное самому себе только по названию (NaN),
--- отвергается там же: сравнения с ним ложны все сразу, и срок из него
--- истекает то мгновенно, то никогда — в зависимости от того, с какой
--- стороны на него посмотрели.
---@param value any
---@param field string
---@param default number Что взять, если не задано
---@param least number Нижняя граница
---@return number
function Module.number(value, field, default, least)
    if value == nil then
        return default
    end

    if type(value) ~= 'number' or value ~= value then
        error(('настройка %s должна быть числом'):format(field))
    end

    if value == math.huge or value == -math.huge then
        error(('настройка %s не может быть бесконечной'):format(field))
    end

    if value < least then
        error(('настройка %s не может быть меньше %s'):format(field, least))
    end

    return value
end

--- Проверенный срок ожидания.
---
--- Ноль здесь значит «ждать без срока», и именно поэтому запрещён: файбер,
--- ждущий соединения без срока, не ждёт никого — его не разбудит ни отказ
--- службы, ни закрытие пула, — и заметить его можно только по тому, что
--- запрос не ответил никогда.
---@param value any
---@param default number
---@return number
function Module.wait_of(value, default)
    local span = Module.number(value, 'wait_timeout', default, 0)

    if span == 0 then
        error('срок ожидания обязателен: без него ждут навсегда')
    end

    return span
end

--- Настройки пула, как их даёт вызывающий. Других ключей нет: незнакомый —
--- отказ. Средство — функция либо таблица с `__call`.
---@class TntPoolOptions
---@field open fun(left: number): any, any Открывает соединение не дольше left секунд; отказ — `nil, причина`
---@field close (fun(conn: any))|nil Закрывает соединение
---@field alive (fun(conn: any): boolean)|nil Живо ли соединение
---@field reset (fun(conn: any): boolean)|nil Сбрасывает состояние перед возвратом
---@field size number|nil Сколько соединений держать; целое
---@field idle_timeout number|nil Сколько позволено простаивать; 0 — сколько угодно
---@field wait_timeout number|nil Сколько ждать свободного; нулём быть не может
---@field max_lifetime number|nil Сколько жить с открытия; 0 — сколько угодно
---@field open_cooldown number|nil Пауза после отказа открытия; 0 — без паузы
---@field leak_timeout number|nil С какого удержания кричать об утечке; 0 — не кричать
---@field sweep_interval number|nil Такт уборки; 0 — убирать только по требованию
---@field name string|nil Имя пула в журнале

---@class TntPoolSettings: TntPoolOptions
---@field open fun(left: number): any, any
---@field close (fun(conn: any))|nil
---@field alive (fun(conn: any): boolean)|nil
---@field reset (fun(conn: any): boolean)|nil
---@field size number
---@field idle_timeout number
---@field wait_timeout number
---@field max_lifetime number
---@field open_cooldown number
---@field leak_timeout number
---@field sweep_interval number
---@field name string

--- Проверяет настройки и дополняет их умолчаниями.
---
--- Набор ключей и роды проверяются раньше границ: настройка с опечаткой
--- в имени до разбора не доходит вовсе, и «ключа «idle_timout» нет»
--- говорит о том, что случилось, точнее любого отказа после него.
---@param opts TntPoolOptions|nil
---@return TntPoolSettings
function Module.check(opts)
    local given = owner.optional.table(opts, TITLE) or {}

    owner.options(given, TITLE, OPTIONS)

    return {
        open = given.open,
        close = given.close,
        alive = given.alive,
        reset = given.reset,
        size = Module.number(given.size, 'size', Module.DEFAULT_SIZE, 1),
        wait_timeout = Module.wait_of(given.wait_timeout, Module.DEFAULT_WAIT_TIMEOUT),
        idle_timeout = Module.number(given.idle_timeout, 'idle_timeout', Module.DEFAULT_IDLE_TIMEOUT, 0),
        max_lifetime = Module.number(given.max_lifetime, 'max_lifetime', Module.DEFAULT_MAX_LIFETIME, 0),
        open_cooldown = Module.number(given.open_cooldown, 'open_cooldown', Module.DEFAULT_OPEN_COOLDOWN, 0),
        leak_timeout = Module.number(given.leak_timeout, 'leak_timeout', Module.DEFAULT_LEAK_TIMEOUT, 0),
        sweep_interval = Module.number(given.sweep_interval, 'sweep_interval', Module.DEFAULT_SWEEP_INTERVAL, 0),
        name = given.name or 'pool',
    }
end

return Module
