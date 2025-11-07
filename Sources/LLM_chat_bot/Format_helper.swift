struct TelegramHTMLFormatter {
    /// Функция принимает HTML-текст и возвращает отформатированную строку,
    /// содержащую только поддерживаемые Telegram теги и экранированные спецсимволы.
    static func helper(text: String) -> String {
        // Массив разрешённых тегов и допустимых атрибутов для каждого из них.
        // Ключи — названия тегов (в нижнем регистре), значения:
        //   - пустой словарь {} означает, что у тега не должно быть атрибутов.
        //   - словарь с перечислением разрешённых атрибутов:
        //       "any"  — атрибут разрешён с любым значением (например, href у <a>),
        //       "flag" — разрешён как булевский (без значения или с любым; например, expandable у <blockquote>),
        //       "language" — специальный ключ для class у <code> (разрешены значения, начинающиеся с "language-"),
        //       список строк — явный перечень допустимых значений (например, class="tg-spoiler" у <span>).
        let allowedTags: [String: [String: Any]] = [
            "b": [:], "strong": [:],
            "i": [:], "em": [:],
            "u": [:], "ins": [:],
            "s": [:], "strike": [:], "del": [:],
            "span": ["class": ["tg-spoiler"]],
            "tg-spoiler": [:],
            "a": ["href": "any"],
            "code": ["class": "language"],
            "pre": [:],
            "blockquote": ["expandable": "flag"],
            "tg-emoji": ["emoji-id": "any"]
        ]
        
        var result = ""                // Результирующая строка
        var stack: [(tag: String, allowed: Bool)] = []  // Стек открытых тегов (для вложенности)
        var i = text.startIndex       // Текущая позиция чтения входной строки
        
        // Вспомогательная функция для получения следующего символа (или nil, если конец строки)
        func nextChar(after idx: String.Index) -> Character? {
            return idx < text.endIndex ? text[text.index(after: idx)] : nil
        }
        
        // Основной цикл: посимвольный разбор входного текста.
        while i < text.endIndex {
            let ch = text[i]
            
            if ch == "<" {
                // Начало тега или текстовый символ '<'
                guard let nextCh = nextChar(after: i) else {
                    // Если '<' последний символ строки — трактуем как текст
                    result.append("&lt;")
                    i = text.index(after: i)
                    continue
                }
                if nextCh == "!" {
                    // Комментарий <!--...--> или объявление <!DOCTYPE> — пропускаем до '>'
                    if let endIdx = text[i...].firstIndex(of: ">") {
                        i = text.index(after: endIdx)
                        continue  // пропускаем весь <!...> блок
                    } else {
                        // Нет закрывающего '>' — считаем как обычный символ
                        result.append("&lt;")
                        i = text.index(after: i)
                        continue
                    }
                }
                if nextCh == "?" {
                    // Конструкция <? ... > (напр. <?xml>) — пропускаем аналогично
                    if let endIdx = text[i...].firstIndex(of: ">") {
                        i = text.index(after: endIdx)
                        continue
                    } else {
                        result.append("&lt;")
                        i = text.index(after: i)
                        continue
                    }
                }
                if nextCh == "/" {
                    // Обрабатываем закрывающий тег вида </tag>
                    if let endIdx = text[i...].firstIndex(of: ">") {
                        // Получаем имя тега между '</' и '>'
                        let tagContent = text[text.index(i, offsetBy: 2) ..< endIdx]  // между </ и >
                        let tagName = tagContent.split(separator: " ", maxSplits: 1).first?.lowercased() ?? ""
                        if !stack.isEmpty {
                            let (openTag, wasAllowed) = stack.removeLast()
                            // Проверяем соответствие имени закрывающего тега последнему открытому
                            if tagName == openTag && wasAllowed {
                                // Если тег разрешён, добавляем его закрытие
                                result.append("</\(tagName)>")
                            }
                            // Если имя не совпадает или тег не разрешён, просто игнорируем закрывающий тег
                        }
                        i = text.index(after: endIdx)
                        continue
                    } else {
                        // Если нет '>', трактуем '<' как текст
                        result.append("&lt;")
                        i = text.index(after: i)
                        continue
                    }
                }
                // Иначе это должен быть открывающий тег. Проверим, что имя тега начинается с буквы.
                if !nextCh.isLetter {
                    // Если после '<' не буква (например, пробел или цифра) — невалидный тег, выводим как текст '<'
                    result.append("&lt;")
                    i = text.index(after: i)
                    continue
                }
                // Найдём конец тега '>'
                guard let tagCloseIdx = text[i...].firstIndex(of: ">") else {
                    // Если '>' не найден, выводим оставшуюся часть как текст
                    result.append("&lt;")
                    i = text.index(after: i)
                    continue
                }
                // Извлекаем содержимое тега (между '<' и '>')
                var tagContent = String(text[text.index(after: i) ..< tagCloseIdx])
                let isSelfClosing = tagContent.hasSuffix("/")  // флаг самозакрывающегося тега (напр. "<br/>")
                if isSelfClosing {
                    // Убираем завершающий слеш '/' перед '>'
                    tagContent = String(tagContent.dropLast().trimmingCharacters(in: .whitespacesAndNewlines))
                }
                // Получаем название тега и строку атрибутов (если есть)
                let parts = tagContent.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                let tagName = parts.first?.lowercased() ?? ""
                let attrString = (parts.count > 1 ? String(parts[1]) : "")
                
                // *** Особая обработка некоторых неподдерживаемых тегов ***
                if tagName == "script" || tagName == "style" {
                    // Полностью пропускаем содержимое <script> или <style> вместе с закрывающим тегом
                    let closingTag = "</\(tagName)>"
                    if let range = text[tagCloseIdx...].range(of: closingTag, options: .caseInsensitive) {
                        // Пропускаем до конца найденного закрывающего тега
                        i = range.upperBound
                    } else {
                        // Если закрывающий тег не найден, пропускаем всё оставшееся
                        i = text.index(after: tagCloseIdx)
                    }
                    // Не выводим ничего (удаляем и тег, и его содержимое)
                    continue
                }
                
                // Флаг разрешённости данного тега
                var allowedTag = false
                var outputTag = ""  // отформатированный тег для вывода (если разрешён)
                
                if let allowedAttrs = allowedTags[tagName] {
                    // Тег в списке разрешённых. Будем проверять и фильтровать атрибуты.
                    allowedTag = true
                    var outputAttrs: [String] = []
                    
                    // Разбираем строку атрибутов посимвольно, чтобы корректно обработать кавычки и пробелы.
                    var j = attrString.startIndex
                    while j < attrString.endIndex {
                        // Пропускаем начальные пробелы
                        if attrString[j].isWhitespace {
                            j = attrString.index(after: j)
                            continue
                        }
                        // Читаем имя атрибута до знака '=' или до пробела
                        var k = j
                        while k < attrString.endIndex, !attrString[k].isWhitespace, attrString[k] != "=" {
                            k = attrString.index(after: k)
                        }
                        let attrName = attrString[j..<k].lowercased()
                        // Подготовимся к чтению значения (если есть)
                        while k < attrString.endIndex, attrString[k].isWhitespace {
                            k = attrString.index(after: k)
                        }
                        var attrValue: String? = nil
                        if k < attrString.endIndex, attrString[k] == "=" {
                            k = attrString.index(after: k)  // пропустить '='
                            // Пропустить пробелы после '='
                            while k < attrString.endIndex, attrString[k].isWhitespace {
                                k = attrString.index(after: k)
                            }
                            if k < attrString.endIndex {
                                if attrString[k] == "\"" || attrString[k] == "'" {
                                    // Значение в кавычках
                                    let quoteChar = attrString[k]
                                    // Найти конец кавычки
                                    var q = attrString.index(after: k)
                                    while q < attrString.endIndex, attrString[q] != quoteChar {
                                        q = attrString.index(after: q)
                                    }
                                    // Извлекаем значение между кавычками (без самих кавычек)
                                    attrValue = String(attrString[attrString.index(after: k) ..< (q < attrString.endIndex ? q : attrString.endIndex)])
                                    k = (q < attrString.endIndex) ? attrString.index(after: q) : attrString.endIndex
                                } else {
                                    // Значение без кавычек (до следующего пробела или конца строки)
                                    var q = k
                                    while q < attrString.endIndex, !attrString[q].isWhitespace {
                                        q = attrString.index(after: q)
                                    }
                                    attrValue = String(attrString[k..<q])
                                    k = q
                                }
                            } else {
                                attrValue = ""  // атрибут имеет '=' но без значения (пустое значение)
                            }
                        } else {
                            // Атрибут без значения (например, "expandable")
                            attrValue = nil
                        }
                        
                        // Проверяем, разрешён ли этот атрибут для данного тега:
                        if let rule = allowedAttrs[attrName] {
                            switch rule {
                            case is String:
                                // Правило задано строкой
                                let ruleStr = rule as! String
                                if ruleStr == "any" {
                                    // Разрешён любой атрибут (любое значение)
                                    if let val = attrValue {
                                        // Экранируем спецсимволы <, > и & в значении
                                        let safeVal = val
                                            .replacingOccurrences(of: "&", with: "&amp;")
                                            .replacingOccurrences(of: "<", with: "&lt;")
                                            .replacingOccurrences(of: ">", with: "&gt;")
                                        outputAttrs.append("\(attrName)=\"\(safeVal)\"")
                                    } else {
                                        // Булевский атрибут без значения (например, просто 'checked')
                                        outputAttrs.append(attrName)
                                    }
                                } else if ruleStr == "flag" {
                                    // Разрешён булевский атрибут (любое значение трактуем как наличие атрибута)
                                    outputAttrs.append(attrName)
                                } else if ruleStr == "language" {
                                    // Разрешён атрибут class с префиксом "language-"
                                    if let val = attrValue, val.starts(with: "language-") {
                                        let safeVal = val
                                            .replacingOccurrences(of: "&", with: "&amp;")
                                            .replacingOccurrences(of: "<", with: "&lt;")
                                            .replacingOccurrences(of: ">", with: "&gt;")
                                        outputAttrs.append("\(attrName)=\"\(safeVal)\"")
                                    }
                                }
                            case is [String]:
                                // Правило задано списком допустимых значений
                                let allowedValues = rule as! [String]
                                if let val = attrValue, allowedValues.contains(val) {
                                    outputAttrs.append("\(attrName)=\"\(val)\"")
                                }
                            default:
                                break
                            }
                        }
                        // Переходим к следующему атрибуту
                        j = k
                    }
                    
                    // Дополнительные условия для некоторых тегов:
                    if tagName == "span" {
                        // Для <span> требуем наличие class="tg-spoiler", иначе тег не разрешён
                        let hasSpoilerClass = outputAttrs.contains(where: { $0.lowercased().starts(with: "class=") && $0.lowercased().contains("tg-spoiler") })
                        if !hasSpoilerClass {
                            allowedTag = false
                        }
                    }
                    if tagName == "a" {
                        // Для <a> требуем наличие href (ссылки), иначе убираем тег
                        let hasHref = outputAttrs.contains(where: { $0.lowercased().starts(with: "href=") })
                        if !hasHref {
                            allowedTag = false
                        }
                    }
                    if tagName == "tg-emoji" {
                        // Для <tg-emoji> требуем наличие атрибута emoji-id
                        let hasId = outputAttrs.contains(where: { $0.lowercased().starts(with: "emoji-id=") })
                        if !hasId {
                            allowedTag = false
                        }
                    }
                    if tagName == "code" {
                        // Для <code>: если есть class с языком, разрешаем его только внутри <pre>
                        if outputAttrs.contains(where: { $0.lowercased().starts(with: "class=") }) {
                            // Проверяем, находится ли сейчас внутри <pre>
                            let insidePre = stack.contains(where: { $0.tag == "pre" && $0.allowed })
                            if !insidePre {
                                // Если <pre> не открыт, убираем class (не разрешаем указание языка вне <pre>)
                                outputAttrs.removeAll(where: { $0.lowercased().starts(with: "class=") })
                            }
                        }
                    }
                    
                    // Формируем открывающий тег для вывода, если он ещё считается разрешённым
                    if allowedTag {
                        outputTag = "<\(tagName)"
                        if !outputAttrs.isEmpty {
                            outputTag += " " + outputAttrs.joined(separator: " ")
                        }
                        outputTag += isSelfClosing ? " />" : ">"
                    }
                } else {
                    // Тег не найден в списке разрешённых
                    if tagName == "br" {
                        // Специально: заменяем <br> на символ перевода строки
                        result.append("\n")
                        i = text.index(after: tagCloseIdx)
                        continue  // пропускаем сам тег (не добавляем его в стек)
                    }
                    // Иные неразрешённые теги просто будут удалены (экранироваться не будем, чтобы не показывать их пользователю).
                    allowedTag = false
                }
                
                // Если тег не самозакрывающийся, добавляем его в стек (даже если не разрешён — для последующего правильного пропуска закрывающих тегов).
                if !isSelfClosing {
                    stack.append((tag: tagName, allowed: allowedTag))
                }
                // Выводим открывающий тег, если он разрешён
                if allowedTag, !outputTag.isEmpty {
                    result += outputTag
                }
                // Переходим за '>' текущего тега и продолжаем разбор
                i = text.index(after: tagCloseIdx)
                continue
            }
            
            // Обработка обычного текста (не внутри тега):
            if ch == "&" {
                // Встречена амперсанд - проверим, не является ли он началом HTML-сущности.
                // Telegram поддерживает ограниченный набор именованных сущностей и все числовые.
                if let semiIdx = text[text.index(after: i)...].firstIndex(of: ";") {
                    let entity = String(text[i...semiIdx])  // например, &lt; или &copy;
                    // Разрешённые именованные сущности:
                    if entity == "&lt;" || entity == "&gt;" || entity == "&amp;" || entity == "&quot;" {
                        result.append(entity)
                        i = text.index(after: semiIdx)
                        continue
                    }
                    // Разрешённые числовые сущности (десятичные или шестнадцатеричные)
                    if entity.hasPrefix("&#") {
                        // Пример: &#1234; или &#x1Af;
                        let numString = String(entity.dropFirst(2).dropLast())  // без &# и ;
                        if numString.first == "x" || numString.first == "X" {
                            // шестнадцатеричный код
                            let hexPart = String(numString.dropFirst())
                            if !hexPart.isEmpty, hexPart.allSatisfy({ $0.isHexDigit }) {
                                result.append(entity)
                                i = text.index(after: semiIdx)
                                continue
                            }
                        } else {
                            // десятичный код
                            if !numString.isEmpty, numString.allSatisfy({ $0.isNumber }) {
                                result.append(entity)
                                i = text.index(after: semiIdx)
                                continue
                            }
                        }
                    }
                }
                // Если это не поддерживаемая сущность, заменяем '&' на &amp;
                result.append("&amp;")
                i = text.index(after: i)
                continue
            }
            if ch == "<" {
                // Одиночный символ '<' вне контекста тега (например, "2 < 3") – экранируем
                result.append("&lt;")
                i = text.index(after: i)
                continue
            }
            if ch == ">" {
                // Одиночный '>' в тексте – экранируем
                result.append("&gt;")
                i = text.index(after: i)
                continue
            }
            // Обычный символ, просто добавляем его
            result.append(ch)
            i = text.index(after: i)
        }
        
        // После обработки всей строки, закрываем незакрытые разрешённые теги (для корректности HTML).
        while !stack.isEmpty {
            let (openTag, wasAllowed) = stack.removeLast()
            if wasAllowed {
                result.append("</\(openTag)>")
            }
            // Неразрешённые теги просто пропускаются при закрытии.
        }
        
        return result
    }
}

// Примеры использования:
let input1 = "Hello <strong>world</strong> & 2 < 3!"
let output1 = TelegramHTMLFormatter.helper(text: input1)
// Ожидаемый результат: "Hello <strong>world</strong> &amp; 2 &lt; 3!"

let input2 = "Example: <code class=\"language-python\">var x = 5 < 10</code> and a <span style=\"color:red\">red text</span>."
let output2 = TelegramHTMLFormatter.helper(text: input2)
// Ожидаемый результат: "Example: <code>var x = 5 &lt; 10</code> and a red text."

let input3 = "Спойлер: <tg-spoiler>тайный текст</tg-spoiler> и <span class=\"tg-spoiler\">ещё тайна</span>."
let output3 = TelegramHTMLFormatter.helper(text: input3)
// Ожидаемый результат: "Спойлер: <tg-spoiler>тайный текст</tg-spoiler> и <span class=\"tg-spoiler\">ещё тайна</span>."
