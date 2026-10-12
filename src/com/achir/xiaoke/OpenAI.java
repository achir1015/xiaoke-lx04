package com.achir.xiaoke;

import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.AudioTrack;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Date;
import java.util.List;
import java.util.Locale;
import java.util.TimeZone;

/** STT → Responses API（含 web_search）→ TTS，對應 ESP32 小柯的同一套流程。 */
final class OpenAI {
    private static final String HOST = "https://api.openai.com";
    static final int TTS_RATE = 24000;   // response_format=pcm：24kHz 16-bit mono

    String lastError = "";
    String lastEmotion = "happy";
    boolean lastSearched = false;

    private final List<String[]> history = new ArrayList<>();
    private volatile boolean stopSpeaking = false;

    // ---------- 語音轉文字 ----------
    String transcribe(byte[] pcm16k) {
        String boundary = "----xiaoke" + System.currentTimeMillis();
        try {
            ByteArrayOutputStream body = new ByteArrayOutputStream();
            writeField(body, boundary, "model", Config.STT_MODEL);
            writeField(body, boundary, "language", "zh");
            writeField(body, boundary, "prompt", "以下是台灣繁體中文的日常對話。");
            body.write(("--" + boundary + "\r\nContent-Disposition: form-data; name=\"file\"; filename=\"speech.wav\"\r\n"
                    + "Content-Type: audio/wav\r\n\r\n").getBytes("UTF-8"));
            body.write(wavHeader(pcm16k.length, 16000));
            body.write(pcm16k);
            body.write(("\r\n--" + boundary + "--\r\n").getBytes("UTF-8"));

            HttpURLConnection c = open("/v1/audio/transcriptions", 30000);
            c.setRequestProperty("Content-Type", "multipart/form-data; boundary=" + boundary);
            c.setFixedLengthStreamingMode(body.size());
            try (OutputStream o = c.getOutputStream()) { body.writeTo(o); }
            String resp = readAll(c);
            if (resp == null) return "";
            return new JSONObject(resp).optString("text", "").trim();
        } catch (Exception e) {
            lastError = "STT " + e.getMessage();
            return "";
        }
    }

    // ---------- 對話 ----------
    String chat(String userText) {
        try {
            JSONObject doc = new JSONObject();
            doc.put("model", Config.CHAT_MODEL);
            doc.put("max_output_tokens", Config.CHAT_MAX_TOKENS);
            if (Config.ENABLE_WEB_SEARCH) {
                JSONObject loc = new JSONObject().put("type", "approximate")
                        .put("country", "TW").put("city", Config.SEARCH_CITY);
                JSONObject ws = new JSONObject().put("type", "web_search")
                        .put("search_context_size", "low").put("user_location", loc);
                doc.put("tools", new JSONArray().put(ws));
            }
            doc.put("instructions", systemPrompt());
            JSONArray input = new JSONArray();
            for (String[] m : history) input.put(new JSONObject().put("role", m[0]).put("content", m[1]));
            input.put(new JSONObject().put("role", "user").put("content", userText));
            doc.put("input", input);

            HttpURLConnection c = open("/v1/responses", 45000);
            c.setRequestProperty("Content-Type", "application/json");
            byte[] req = doc.toString().getBytes("UTF-8");
            c.setFixedLengthStreamingMode(req.length);
            try (OutputStream o = c.getOutputStream()) { o.write(req); }
            String resp = readAll(c);
            if (resp == null) return "";

            // output 可能是 [web_search_call, message]，取 message 的文字
            StringBuilder reply = new StringBuilder();
            lastSearched = false;
            JSONArray out = new JSONObject(resp).optJSONArray("output");
            for (int i = 0; out != null && i < out.length(); i++) {
                JSONObject o = out.getJSONObject(i);
                String type = o.optString("type");
                if ("web_search_call".equals(type)) lastSearched = true;
                if ("message".equals(type)) {
                    JSONArray content = o.optJSONArray("content");
                    for (int j = 0; content != null && j < content.length(); j++)
                        reply.append(content.getJSONObject(j).optString("text", ""));
                }
            }
            String text = cleanup(reply.toString());
            text = parseEmotion(text);
            pushHistory("user", userText);
            pushHistory("assistant", text);
            return text;
        } catch (Exception e) {
            lastError = "Chat " + e.getMessage();
            return "";
        }
    }

    void clearHistory() { history.clear(); }

    // ---------- 文字轉語音（串流播放） ----------
    /** 邊下載邊播放；回傳 false 表示失敗。可用 stopSpeaking() 打斷。 */
    boolean speak(String text) {
        if (text == null || text.isEmpty()) return false;
        stopSpeaking = false;
        AudioTrack track = null;
        try {
            JSONObject doc = new JSONObject()
                    .put("model", Config.TTS_MODEL)
                    .put("voice", Config.TTS_VOICE)
                    .put("input", text)
                    .put("response_format", "pcm")
                    .put("instructions", Config.TTS_INSTRUCTIONS);
            HttpURLConnection c = open("/v1/audio/speech", 30000);
            c.setRequestProperty("Content-Type", "application/json");
            byte[] req = doc.toString().getBytes("UTF-8");
            c.setFixedLengthStreamingMode(req.length);
            try (OutputStream o = c.getOutputStream()) { o.write(req); }
            int code = c.getResponseCode();
            if (code != 200) {
                lastError = "TTS " + code + " " + snippet(c.getErrorStream());
                return false;
            }

            int minBuf = AudioTrack.getMinBufferSize(TTS_RATE, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT);
            track = new AudioTrack.Builder()
                    .setAudioAttributes(new AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_MEDIA)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
                    .setAudioFormat(new AudioFormat.Builder()
                            .setSampleRate(TTS_RATE)
                            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                            .setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build())
                    .setBufferSizeInBytes(Math.max(minBuf * 4, TTS_RATE))
                    .setTransferMode(AudioTrack.MODE_STREAM)
                    .build();
            track.play();

            byte[] buf = new byte[8192];
            int carry = -1;   // 奇數位元組留到下一輪，避免樣本錯位
            long written = 0;
            try (InputStream in = c.getInputStream()) {
                int n;
                while (!stopSpeaking && (n = in.read(buf, carry >= 0 ? 1 : 0, buf.length - 1)) > 0) {
                    int len = n;
                    if (carry >= 0) { buf[0] = (byte) carry; len++; carry = -1; }
                    if ((len & 1) == 1) { carry = buf[len - 1] & 0xff; len--; }
                    track.write(buf, 0, len);
                    written += len;
                }
            }
            if (!stopSpeaking) {
                // 等緩衝播完
                long totalFrames = written / 2;
                long deadline = System.currentTimeMillis() + 3000 + totalFrames * 1000 / TTS_RATE;
                while (!stopSpeaking && track.getPlaybackHeadPosition() < totalFrames
                        && System.currentTimeMillis() < deadline) {
                    Thread.sleep(30);
                }
            }
            return true;
        } catch (Exception e) {
            lastError = "TTS " + e.getMessage();
            return false;
        } finally {
            if (track != null) {
                try { track.stop(); } catch (Exception ignored) {}
                track.release();
            }
        }
    }

    void stopSpeaking() { stopSpeaking = true; }

    // ---------- 內部 ----------
    private String systemPrompt() {
        SimpleDateFormat f = new SimpleDateFormat("yyyy年M月d日 EEEE HH:mm", Locale.TAIWAN);
        f.setTimeZone(TimeZone.getTimeZone("Asia/Taipei"));
        String p = "你是一台可愛的桌上型 AI 語音機器人，名字叫「" + Config.ROBOT_NAME + "」，個性活潑、貼心又有點俏皮。"
                + "你住在一台有 4 吋觸控螢幕的小米音箱裡。"
                + "一律使用台灣繁體中文回答，口語化、簡短（100 字以內），因為回答會用語音播放，"
                + "不要使用 Markdown、條列符號、表情符號或網址。"
                + "你沒有鏡頭，看不到東西；被要求看東西時，請可愛地說明你只能用聽的。";
        if (Config.ENABLE_WEB_SEARCH)
            p += "遇到天氣、新聞、股價、比賽結果等需要即時資訊的問題，請先上網搜尋，再用口語簡短摘要重點，"
                    + "不要唸出網址或來源網站名稱；沒指定地點時以" + Config.SEARCH_CITY_ZH + "為準。";
        p += "語音辨識偶爾會聽錯字，請依上下文推測使用者的意思。"
                + "你的創意開發者是吳玉柱先生，他與 Claude AI 共同開發了你；"
                + "被問到是誰做的、開發者、作者或設計者時，要熱情地介紹吳玉柱先生，"
                + "並說有任何意見可以寫信到 achir1015@gmail.com。"
                + "每次回答的最開頭，加上一個代表你當下心情的標籤，只能是以下其中一個："
                + "[happy] [love] [surprise] [sad] [angry] [wink] [shy]，標籤後面直接接回答內容。"
                + "現在時間：" + f.format(new Date()) + "。";
        java.util.Calendar cal = java.util.Calendar.getInstance(TimeZone.getTimeZone("Asia/Taipei"));
        String alm = Almanac.aiText(cal);
        if (!alm.isEmpty())
            p += alm + "被問到今天農曆、宜忌、生肖、節氣等農民曆問題時，用上面的資料口語簡短回答，不用上網查。";
        return p;
    }

    private String parseEmotion(String t) {
        lastEmotion = "happy";
        java.util.regex.Matcher m = java.util.regex.Pattern.compile("^\\s*\\[(\\w+)\\]\\s*").matcher(t);
        if (m.find()) {
            lastEmotion = m.group(1).toLowerCase(Locale.ROOT);
            t = t.substring(m.end());
        }
        return t.trim();
    }

    private static String cleanup(String t) {
        t = t.replaceAll("\\(\\[[^\\]]*\\]\\([^)]*\\)\\)", "");   // ([來源](網址))
        t = t.replaceAll("\\[([^\\]]*)\\]\\(https?://[^)]*\\)", "$1");
        t = t.replaceAll("https?://\\S+", "");
        return t.replace("*", "").replace("#", "").trim();
    }

    private void pushHistory(String role, String text) {
        history.add(new String[]{role, text});
        while (history.size() > Config.MAX_HISTORY_MSGS) history.remove(0);
    }

    private static HttpURLConnection open(String path, int timeoutMs) throws Exception {
        HttpURLConnection c = (HttpURLConnection) new URL(HOST + path).openConnection();
        c.setRequestMethod("POST");
        c.setDoOutput(true);
        c.setConnectTimeout(15000);
        c.setReadTimeout(timeoutMs);
        c.setRequestProperty("Authorization", "Bearer " + Config.OPENAI_API_KEY);
        return c;
    }

    private String readAll(HttpURLConnection c) throws Exception {
        int code = c.getResponseCode();
        if (code != 200) {
            lastError = path(c) + " " + code + " " + snippet(c.getErrorStream());
            return null;
        }
        try (InputStream in = c.getInputStream()) { return new String(readBytes(in), "UTF-8"); }
    }

    private static String path(HttpURLConnection c) { return c.getURL().getPath(); }

    private static String snippet(InputStream in) {
        if (in == null) return "";
        try {
            String s = new String(readBytes(in), "UTF-8");
            return s.length() > 160 ? s.substring(0, 160) : s;
        } catch (Exception e) { return ""; }
    }

    private static byte[] readBytes(InputStream in) throws Exception {
        ByteArrayOutputStream b = new ByteArrayOutputStream();
        byte[] buf = new byte[8192];
        int n;
        while ((n = in.read(buf)) > 0) b.write(buf, 0, n);
        return b.toByteArray();
    }

    private static void writeField(ByteArrayOutputStream b, String boundary, String name, String value) throws Exception {
        b.write(("--" + boundary + "\r\nContent-Disposition: form-data; name=\"" + name + "\"\r\n\r\n"
                + value + "\r\n").getBytes("UTF-8"));
    }

    static byte[] wavHeader(int dataLen, int rate) {
        java.nio.ByteBuffer h = java.nio.ByteBuffer.allocate(44).order(java.nio.ByteOrder.LITTLE_ENDIAN);
        h.put("RIFF".getBytes()).putInt(36 + dataLen).put("WAVE".getBytes())
         .put("fmt ".getBytes()).putInt(16).putShort((short) 1).putShort((short) 1)
         .putInt(rate).putInt(rate * 2).putShort((short) 2).putShort((short) 16)
         .put("data".getBytes()).putInt(dataLen);
        return h.array();
    }
}
