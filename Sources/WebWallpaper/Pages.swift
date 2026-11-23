import Foundation

/// 未设置网址时显示的默认页面（离线可用）。
enum WelcomePage {

    static let html = """
    <!doctype html>
    <html lang="zh-CN">
    <head>
    <meta charset="utf-8">
    <style>
      html, body { margin: 0; height: 100%; }
      body {
        display: flex; align-items: center; justify-content: center;
        font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif;
        background: linear-gradient(135deg, #dff5ee 0%, #cfe9f5 48%, #f7e4c4 100%);
        color: #2f4858;
      }
      .card {
        text-align: center;
        padding: 56px 76px;
        border-radius: 32px;
        background: rgba(255, 255, 255, 0.55);
        box-shadow: 0 24px 80px rgba(47, 72, 88, 0.16);
        backdrop-filter: blur(18px);
      }
      .clock {
        font-size: clamp(64px, 12vw, 140px);
        font-weight: 700;
        letter-spacing: 4px;
        margin: 0;
        font-variant-numeric: tabular-nums;
      }
      .date { font-size: 24px; opacity: .68; margin-top: 4px; }
      .hint { margin-top: 44px; font-size: 18px; opacity: .72; }
      .hint b { font-weight: 600; }
    </style>
    </head>
    <body>
      <div class="card">
        <p class="clock" id="clock">--:--</p>
        <p class="date" id="date"></p>
        <p class="hint">把任意网页变成桌面壁纸 · 点击菜单栏图标 → <b>设置网址…</b></p>
      </div>
      <script>
        function tick() {
          var now = new Date();
          var pad = function (n) { return String(n).padStart(2, '0'); };
          document.getElementById('clock').textContent = pad(now.getHours()) + ':' + pad(now.getMinutes());
          document.getElementById('date').textContent =
            now.getFullYear() + ' 年 ' + (now.getMonth() + 1) + ' 月 ' + now.getDate() + ' 日 · 星期' +
            '日一二三四五六'.charAt(now.getDay());
        }
        tick();
        setInterval(tick, 1000);
      </script>
    </body>
    </html>
    """
}

/// 网页加载失败时显示的错误页。
enum ErrorPage {

    static func html(url: String, message: String) -> String {
        """
        <!doctype html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8">
        <style>
          html, body { margin: 0; height: 100%; }
          body {
            display: flex; align-items: center; justify-content: center;
            font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif;
            background: linear-gradient(135deg, #f6e7e1 0%, #e8f1f5 100%);
            color: #2f4858;
          }
          .card {
            max-width: 720px;
            padding: 48px 56px;
            border-radius: 28px;
            background: rgba(255, 255, 255, 0.6);
            box-shadow: 0 24px 80px rgba(47, 72, 88, 0.14);
          }
          h1 { font-size: 26px; margin: 0 0 16px; }
          p { font-size: 16px; line-height: 1.7; margin: 8px 0; opacity: .8; word-break: break-all; }
          .url { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 14px; }
        </style>
        </head>
        <body>
          <div class="card">
            <h1>网页加载失败</h1>
            <p class="url">\(escape(url))</p>
            <p>\(escape(message))</p>
            <p>请检查网络或网址是否正确，然后在菜单栏选择「重新载入」或「设置网址…」。</p>
          </div>
        </body>
        </html>
        """
    }

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
