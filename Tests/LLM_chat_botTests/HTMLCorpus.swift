import Foundation

/// Inputs the sanitizer has to survive: every branch of the tag reader, the
/// attribute reader and the entity reader, plus the malformed shapes a model
/// actually produces.
///
/// The expected outputs (`TelegramHTMLFormatterGoldenTests`) were captured from
/// the implementation before it was split into tokenizer/sanitizer/renderer, so
/// they pin the behaviour across that refactor rather than merely describing
/// the code that exists now.
enum HTMLCorpus {
    static let cases: [String] = [
        // plain text and bare specials
        "просто текст",
        "2 < 3 и 5 > 4 & 7",
        "",
        "<",
        ">",
        "&",
        "a < ",
        // allowed tags
        "<b>bold</b>",
        "<strong>x</strong><em>y</em><ins>z</ins><del>w</del>",
        "<tg-spoiler>секрет</tg-spoiler>",
        "<span class=\"tg-spoiler\">секрет</span>",
        "<span>без класса</span>",
        "<span class='tg-spoiler'>одинарные кавычки</span>",
        "<blockquote expandable>цитата</blockquote>",
        "<blockquote expandable=\"true\">цитата</blockquote>",
        "<tg-emoji emoji-id=\"5368324170671202286\">👍</tg-emoji>",
        "<tg-emoji>без id</tg-emoji>",
        // links and schemes
        "<a href=\"https://example.com\">ok</a>",
        "<a href=\"javascript:alert(1)\">bad</a>",
        "<a href=\"data:text/html,x\">bad</a>",
        "<a href=\"//evil.example\">protocol relative</a>",
        "<a href=\"tg://user?id=1\">tg</a>",
        "<a href=\"mailto:a@b.c\">mail</a>",
        "<a href=\"/relative/path\">rel</a>",
        "<a href=\"java\nscript:alert(1)\">smuggled</a>",
        "<a>без href</a>",
        "<a href=\"x\" onclick=\"y\">extra attrs</a>",
        "<a href='x\" onclick=\"y'>quote break</a>",
        // code and pre
        "<pre><code class=\"language-swift\">let x = 1</code></pre>",
        "<code class=\"language-swift\">вне pre</code>",
        "<code class=\"notlanguage\">x</code>",
        "<pre>plain pre</pre>",
        // unknown / dangerous tags
        "<div>inner</div>",
        "<script>alert(1)</script>после",
        "<script>alert(1)",
        "<style>body{}</style>после",
        "<SCRIPT>x</SCRIPT>",
        "<br>перенос",
        "<br/>перенос",
        "<img src=\"x\"/>",
        // malformed
        "<b>не закрыт",
        "<b><i>перекрёстно</b></i>",
        "</b>лишний закрывающий",
        "<b>a</B>",
        "< b>пробел после угла",
        "<3 сердечко",
        "<!-- комментарий -->текст",
        "<!doctype html>текст",
        "<?xml version=\"1.0\"?>текст",
        "<!-- без конца",
        "<b",
        "<b attr",
        // entities
        "&lt;&gt;&amp;&quot;",
        "&copy;",
        "&#1234;",
        "&#x1Af;",
        "&#;",
        "&#xZZ;",
        "&noSemicolon",
        "&amp;amp;",
        // attribute reader corners
        "<blockquote  expandable  >два пробела</blockquote>",
        "<a href = \"https://x.y\" >пробелы вокруг равно</a>",
        "<a href=https://x.y>без кавычек</a>",
        "<a href=\"unterminated>текст</a>",
        "<code CLASS=\"language-py\">верхний регистр</code>",
        // nesting and depth
        "<b><i><u>тройная вложенность</u></i></b>",
        "<blockquote><b>цитата с жирным</b></blockquote>",
        "<pre><code>a &lt; b</code></pre>",
        // real-world-ish
        "Вот пример:\n<pre><code class=\"language-swift\">if a < b { print(\"&\") }</code></pre>\nи <b>вывод</b>.",
    ]
}
