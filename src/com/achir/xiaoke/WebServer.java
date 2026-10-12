package com.achir.xiaoke;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.ServerSocket;
import java.net.Socket;

/**
 * 極簡內建 web server：手機／電腦連同一個 Wi-Fi，開 http://裝置IP:WEB_PORT
 * 就能看到病房助理工作站的所有工具並點擊開啟（首頁左下角顯示的網址）。
 */
final class WebServer {
    private final Portal portal;
    private volatile boolean running;
    private ServerSocket server;

    WebServer(Portal portal) { this.portal = portal; }

    void start() {
        if (running) return;
        running = true;
        new Thread(this::loop, "web").start();
    }

    void stop() {
        running = false;
        try { if (server != null) server.close(); } catch (Exception ignored) {}
    }

    private void loop() {
        try {
            server = new ServerSocket(Config.WEB_PORT);
            while (running) {
                try (Socket s = server.accept()) {
                    handle(s);
                } catch (Exception e) {
                    if (!running) break;
                }
            }
        } catch (Exception ignored) {}
    }

    private void handle(Socket s) throws Exception {
        BufferedReader in = new BufferedReader(new InputStreamReader(s.getInputStream(), "UTF-8"));
        String line = in.readLine();   // 只需起始行，忽略其餘標頭
        while (in.ready()) in.readLine();
        String path = "/";
        if (line != null) {
            String[] parts = line.split(" ");
            if (parts.length >= 2) path = parts[1];
        }
        byte[] body = page().getBytes("UTF-8");
        OutputStream o = s.getOutputStream();
        o.write(("HTTP/1.0 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
                + "Content-Length: " + body.length + "\r\nConnection: close\r\n\r\n").getBytes("UTF-8"));
        o.write(body);
        o.flush();
    }

    private String page() {
        StringBuilder h = new StringBuilder();
        h.append("<!doctype html><html lang=zh-Hant><head><meta charset=utf-8>")
         .append("<meta name=viewport content='width=device-width,initial-scale=1'>")
         .append("<title>").append(Config.PORTAL_NAME).append("</title><style>")
         .append("body{margin:0;background:#0b1020;color:#e8eef7;font-family:system-ui,'Noto Sans TC',sans-serif;padding:16px}")
         .append("h1{font-size:20px;color:#40e8ff;margin:4px 0 16px}")
         .append("h2{font-size:15px;color:#ffb020;border-bottom:1px solid #283448;padding-bottom:4px;margin:20px 0 8px}")
         .append("a{display:block;background:#0e1626;border:1px solid #283448;border-radius:10px;")
         .append("padding:12px 14px;margin:8px 0;color:#e8eef7;text-decoration:none;font-size:16px}")
         .append("a:active{background:#16233a}.u{color:#5b7;font-size:12px;word-break:break-all}")
         .append("</style></head><body><h1>").append(Config.PORTAL_NAME).append("</h1>");
        if (portal.isEmpty()) {
            h.append("<p>工具清單尚未載入。</p>");
        } else {
            for (String cat : portal.cats) {
                h.append("<h2>").append(esc(cat)).append("</h2>");
                int idx = portal.cats.indexOf(cat);
                for (Portal.Tool t : portal.filtered(idx))
                    h.append("<a href='").append(esc(t.url)).append("' target=_blank>")
                     .append(esc(t.full)).append("<div class=u>").append(esc(t.url)).append("</div></a>");
            }
        }
        return h.append("</body></html>").toString();
    }

    private static String esc(String s) {
        return s == null ? "" : s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("'", "&#39;");
    }
}
