-- Locales/ruRU.lua
-- Translator ZamestoTV
--
-- Only strings whose translation is certain are listed. A key left out falls
-- back to English, which is a better outcome than a confident guess: a player
-- reading English knows what it means, and a player reading a mistranslation
-- does not know that is what they are reading.

local ADDON_NAME, CN = ...

CN.RegisterLocale("ruRU", {
    ["Next"] = "Далее",
    ["Zone"] = "Зона",
    ["Scans"] = "Сканирование",
    ["Now"] = "Сейчас",
    ["Warband"] = "Отряд",
    ["Vault"] = "Хранилище",
    ["Goals"] = "Цели",
    ["Journey"] = "Путешествие",
    ["Remaining"] = "Осталось",
    ["Collections"] = "Коллекции",
    ["Settings"] = "Настройки",
    ["Destination"] = "Пункт назначения",
    ["distance unknown"] = "расстояние неизвестно",
    ["no position"] = "нет координат",
    ["another zone"] = "другая зона",
    ["Arrived: %s"] = "Прибытие: %s",
    ["Now heading to: %s"] = "Сейчас направляюсь к: %s",
    ["ahead"] = "впереди",
    ["veer"] = "плавный поворот",
    ["turn"] = "поворот",
    ["back"] = "назад",
    ["account-wide"] = "на всю учетную запись",
    ["nothing actionable"] = "нет доступных действий",
    ["Stop cleared"] = "Точка маршрута пройдена",
    ["Stop %d of %d cleared"] = "Точка %d из %d пройдена",
    ["Route complete."] = "Маршрут завершен.",
    ["All %d stops done."] = "Все точки (%d) пройдены.",
    ["All 1 stop done."] = "Единственная точка пройдена.",
    ["stop %d of %d"] = "точка %d из %d",
    ["estimated"] = "расчетное время",
    ["unknown"] = "неизвестно",
    ["solo"] = "соло",
    ["dead"] = "мертв",
    ["grouped"] = "в группе",
    ["instanced"] = "в подземелье/рейде",
    ["%d more"] = "еще %d",
    
    -- 1.10.0. The words the addon says instead of presenting an answer
    -- built from data it knows has not arrived yet.
    ["Still hearing back about %s; this may change."] = "Всё ещё ожидаем данные о: %s; ситуация может измениться.",
    ["your lockouts"] = "ваших сохранениях подземелий",
    ["your mailbox"] = "вашем почтовом ящике",
    ["The replies landed: %s rather than %s."] = "Получены ответы: %s вместо %s.",
})
