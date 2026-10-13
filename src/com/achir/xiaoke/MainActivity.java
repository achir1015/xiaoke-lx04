package com.achir.xiaoke;

import android.Manifest;
import android.app.Activity;
import android.content.Context;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioRecord;
import android.media.MediaRecorder;
import android.net.wifi.WifiManager;
import android.graphics.Color;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.view.WindowManager;
import android.webkit.GeolocationPermissions;
import android.webkit.PermissionRequest;
import android.webkit.WebChromeClient;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.LinearLayout;
import android.widget.MediaController;
import android.widget.TextView;
import android.widget.VideoView;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.Toast;

import java.io.ByteArrayOutputStream;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.util.ArrayDeque;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

public class MainActivity extends Activity {
    private static final int RATE = 16000;
    private static final int FRAME = 480;              // 30ms
    private static final int FRAME_MS = 30;
    private static final int PREROLL_FRAMES = 10;      // 說話前保留 300ms

    private FaceView face;
    private final OpenAI ai = new OpenAI();
    private final Portal portal = new Portal();
    private final Music music = new Music();
    private volatile boolean interrupted;   // 這一輪被點螢幕打斷
    private FrameLayout mvLayer;
    private VideoView mvView;
    private Button mvPause;
    private TextView mvTitle;
    private WebServer web;
    private WebView wv;
    private Button webBar;
    private volatile boolean running;
    private volatile boolean manualListen;
    private volatile boolean webShown;     // 網頁 / Stream Deck 開著時不偵測語音
    private volatile boolean deckBusy;
    private volatile long lastActive = System.currentTimeMillis();
    private Thread worker;
    private final Handler ui = new Handler(Looper.getMainLooper());
    private final Runnable chipTick = new Runnable() {
        @Override public void run() { updateChips(); ui.postDelayed(this, 3000); }
    };

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
                | WindowManager.LayoutParams.FLAG_FULLSCREEN);
        face = new FaceView(this);
        face.setStatus("嗨！我是" + Config.ROBOT_NAME + "，有什麼想聊的嗎？");
        face.setOnTouchListener(this::onTouch);
        face.setOnLongClickListener(v -> { showInfo(); return true; });

        FrameLayout root = new FrameLayout(this);
        root.addView(face, new FrameLayout.LayoutParams(-1, -1));
        buildWebUi(root);
        buildMvUi(root);
        setContentView(root);
        hideSystemUi();

        portal.load(this);
        music.load(this);
        face.setPortal(portal);
        face.setToolListener((url, name) -> openTool(url, "‹ 返回工作站"));   // 點工具 → 直接在螢幕上開網頁
        face.setDeckListener(this::openDeck);                   // Stream Deck（Macro Deck 網頁用戶端）
        web = new WebServer(portal);
        web.start();
        updateChips();
    }

    // 在裝置螢幕上直接開啟工具網頁（可觸控操作），上方一條返回列
    @SuppressWarnings("SetJavaScriptEnabled")
    private void buildWebUi(FrameLayout root) {
        wv = new WebView(this);
        WebSettings ws = wv.getSettings();
        ws.setJavaScriptEnabled(true);
        ws.setDomStorageEnabled(true);
        ws.setUseWideViewPort(true);
        ws.setLoadWithOverviewMode(true);
        ws.setBuiltInZoomControls(true);
        ws.setDisplayZoomControls(false);
        ws.setMediaPlaybackRequiresUserGesture(false);
        ws.setGeolocationEnabled(true);
        wv.setWebViewClient(new WebViewClient() {
            @Override public boolean shouldOverrideUrlLoading(WebView v, String u) { return false; }
            @Override public void onReceivedError(WebView v, int code, String desc, String url) {
                if (url != null && url.equals(deckUrl)) {           // 電腦的 Macro Deck 關了或換 IP
                    prefs().edit().remove("deck").apply();
                    closeWeb();
                    face.setStatus("連不上 Macro Deck，再點一次 Stream Deck 重新尋找");
                }
            }
        });
        wv.setWebChromeClient(new WebChromeClient() {
            @Override public void onPermissionRequest(PermissionRequest r) {
                runOnUiThread(() -> r.grant(r.getResources()));          // 允許網頁用鏡頭/麥克風
            }
            @Override public void onGeolocationPermissionsShowPrompt(String o, GeolocationPermissions.Callback cb) {
                cb.invoke(o, true, false);                               // 允許定位（GPS 工具）
            }
        });
        wv.setVisibility(View.GONE);
        root.addView(wv, new FrameLayout.LayoutParams(-1, -1));

        webBar = new Button(this);
        webBar.setAllCaps(false);
        webBar.setText("‹ 返回工作站");
        webBar.setTextColor(Color.WHITE);
        webBar.setBackgroundColor(0xE6162A42);
        webBar.setVisibility(View.GONE);
        webBar.setOnClickListener(v -> { if (wv.canGoBack()) wv.goBack(); else closeWeb(); });
        FrameLayout.LayoutParams lp = new FrameLayout.LayoutParams(-2, -2);
        lp.gravity = Gravity.TOP | Gravity.START;
        lp.leftMargin = 16; lp.topMargin = 16;
        root.addView(webBar, lp);
    }

    private void openTool(String url, String back) {
        ai.stopSpeaking();
        music.stop();
        webShown = true;
        webBar.setText(back);
        wv.setVisibility(View.VISIBLE);
        webBar.setVisibility(View.VISIBLE);
        webBar.bringToFront();
        wv.loadUrl(url);
    }

    private void closeWeb() {
        webShown = false;
        deckUrl = null;
        wv.setVisibility(View.GONE);
        webBar.setVisibility(View.GONE);
        wv.loadUrl("about:blank");
        hideSystemUi();
    }

    private boolean webOpen() { return wv != null && wv.getVisibility() == View.VISIBLE; }

    // ---------------- Stream Deck ----------------
    // 電腦裝 Macro Deck 2（免費開源），它內建網頁用戶端 http://電腦IP:8191；這裡全螢幕開它當按鍵面板。
    private String deckUrl;

    private SharedPreferences prefs() { return getSharedPreferences("xiaoke", MODE_PRIVATE); }

    void openDeck() {
        if (deckBusy) return;
        deckBusy = true;
        face.setStatus("尋找電腦上的 Macro Deck…");
        new Thread(() -> {
            String url = findDeck();
            deckBusy = false;
            runOnUiThread(() -> {
                if (url == null) { face.setStatus("找不到 Macro Deck（電腦要開 Macro Deck 2，同一個 Wi-Fi）"); return; }
                face.setStatus("");
                prefs().edit().putString("deck", url).apply();
                deckUrl = url;
                openTool(url, "‹ 小柯");
                webBar.setAlpha(0.55f);   // 半透明，少擋按鍵
            });
        }, "deck-scan").start();
    }

    /** 依序試：Config 指定 → 上次找到的 → 掃描同網段 /24 的 8191 埠。 */
    private String findDeck() {
        if (!Config.MACRO_DECK_URL.isEmpty()) return Config.MACRO_DECK_URL;
        String last = prefs().getString("deck", "");
        if (!last.isEmpty() && reachable(hostOf(last), 600)) return last;
        int ip;
        try {
            ip = ((WifiManager) getApplicationContext().getSystemService(Context.WIFI_SERVICE)).getConnectionInfo().getIpAddress();
        } catch (Exception e) { return null; }
        if (ip == 0) return null;
        String prefix = (ip & 0xff) + "." + ((ip >> 8) & 0xff) + "." + ((ip >> 16) & 0xff) + ".";
        AtomicReference<String> found = new AtomicReference<>();
        ExecutorService pool = Executors.newFixedThreadPool(48);
        for (int i = 1; i < 255; i++) {
            String h = prefix + i;
            pool.execute(() -> { if (found.get() == null && reachable(h, 400)) found.compareAndSet(null, h); });
        }
        pool.shutdown();
        try { pool.awaitTermination(8, TimeUnit.SECONDS); } catch (InterruptedException ignored) {}
        pool.shutdownNow();
        return found.get() == null ? null : "http://" + found.get() + ":" + Config.MACRO_DECK_PORT;
    }

    private static String hostOf(String url) { return android.net.Uri.parse(url).getHost(); }

    private static boolean reachable(String host, int timeoutMs) {
        try (Socket so = new Socket()) {
            so.connect(new InetSocketAddress(host, Config.MACRO_DECK_PORT), timeoutMs);
            return true;
        } catch (Exception e) { return false; }
    }

    @Override
    public void onBackPressed() {
        if (mvOpen()) { closeMV(); return; }
        if (webOpen()) { if (wv.canGoBack()) wv.goBack(); else closeWeb(); return; }
        if (face.isPortalOpen()) { face.closePortal(); return; }
        super.onBackPressed();
    }

    // 上方音量％與左下 IP（農民曆首頁用）
    private void updateChips() {
        try {
            AudioManager am = (AudioManager) getSystemService(Context.AUDIO_SERVICE);
            int max = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC);
            int cur = am.getStreamVolume(AudioManager.STREAM_MUSIC);
            face.setVolume(max > 0 ? Math.round(cur * 100f / max) : 0);
        } catch (Exception ignored) {}
        face.setIp(ipText());
    }

    private String ipText() {
        try {
            WifiManager wm = (WifiManager) getApplicationContext().getSystemService(Context.WIFI_SERVICE);
            int ip = wm.getConnectionInfo().getIpAddress();
            if (ip != 0)
                return String.format("http://%d.%d.%d.%d:%d", ip & 0xff, (ip >> 8) & 0xff, (ip >> 16) & 0xff, (ip >> 24) & 0xff, Config.WEB_PORT);
        } catch (Exception ignored) {}
        return "";
    }

    @Override
    protected void onResume() {
        super.onResume();
        hideSystemUi();
        ui.removeCallbacks(chipTick);
        ui.post(chipTick);
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{Manifest.permission.RECORD_AUDIO}, 1);
            return;
        }
        startWorker();
    }

    @Override
    public void onRequestPermissionsResult(int code, String[] perms, int[] results) {
        if (results.length > 0 && results[0] == PackageManager.PERMISSION_GRANTED) startWorker();
        else face.setStatus("需要麥克風權限才能聊天喔");
    }

    @Override
    protected void onPause() {
        super.onPause();
        running = false;
        ai.stopSpeaking();
        music.stop();
        closeMV();
        ui.removeCallbacks(chipTick);
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
        if (web != null) web.stop();
    }

    private void hideSystemUi() {
        getWindow().getDecorView().setSystemUiVisibility(View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                | View.SYSTEM_UI_FLAG_FULLSCREEN | View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY);
    }

    private long downAt;

    private boolean onTouch(View v, MotionEvent e) {
        if (e.getAction() == MotionEvent.ACTION_DOWN) downAt = System.currentTimeMillis();
        if (e.getAction() == MotionEvent.ACTION_UP && System.currentTimeMillis() - downAt < 500) {
            lastActive = System.currentTimeMillis();
            if (face.handleTouch(e.getX(), e.getY())) return true;        // 工作站選單吃掉這一下
            FaceView.State s = face.getState();
            if (s == FaceView.State.SPEAKING) { interrupted = true; ai.stopSpeaking(); music.stop(); }   // 打斷（說話或唱歌）
            else if (s != FaceView.State.THINKING) manualListen = true;   // 點一下開始聽
        }
        return false;   // 讓長按事件繼續
    }

    private void showInfo() {
        String err = ai.lastError.isEmpty() ? "無" : ai.lastError;
        Toast.makeText(this, Config.ROBOT_NAME + " v1.0\n模型：" + Config.CHAT_MODEL
                + "\n最近錯誤：" + err + "\n（對話記憶已清除）", Toast.LENGTH_LONG).show();
        ai.clearHistory();
    }

    // ---------------- 主迴圈 ----------------
    private synchronized void startWorker() {
        if (running && worker != null && worker.isAlive()) return;
        running = true;
        worker = new Thread(this::loop, "xiaoke");
        worker.start();
    }

    private void loop() {
        AudioRecord rec = openMic();
        if (rec == null) {
            face.setState(FaceView.State.ERROR);
            face.setStatus("打不開麥克風（可能被小愛同學佔用）");
            running = false;
            return;
        }
        short[] buf = new short[FRAME];
        double noise = 150;
        ArrayDeque<short[]> preroll = new ArrayDeque<>();
        face.setState(FaceView.State.IDLE);
        try {
            rec.startRecording();
            while (running) {
                int n = rec.read(buf, 0, FRAME);
                if (n <= 0) continue;
                double rms = rms(buf, n);
                boolean loud = Config.VOICE_ACTIVATION && !webShown
                        && rms > Math.max(Config.VAD_MIN_RMS, noise * Config.VAD_RATIO);

                if (!loud && !manualListen) {
                    noise = noise * 0.97 + rms * 0.03;
                    preroll.addLast(buf.clone());
                    if (preroll.size() > PREROLL_FRAMES) preroll.removeFirst();
                    updateIdle();
                    continue;
                }

                boolean manual = manualListen;
                manualListen = false;
                byte[] pcm = record(rec, preroll, buf, noise, manual);
                preroll.clear();
                rec.stop();
                if (pcm != null) handleSpeech(pcm);
                lastActive = System.currentTimeMillis();
                if (!running) break;
                face.setState(FaceView.State.IDLE);
                rec.startRecording();
                drain(rec, buf, 300);   // 丟掉喇叭殘響
            }
        } finally {
            try { rec.stop(); } catch (Exception ignored) {}
            rec.release();
        }
    }

    private void updateIdle() {
        boolean sleepy = System.currentTimeMillis() - lastActive > Config.SLEEPY_AFTER_SEC * 1000L;
        FaceView.State s = face.getState();
        if (sleepy && s == FaceView.State.IDLE) face.setState(FaceView.State.SLEEPY);
        if (!sleepy && s == FaceView.State.SLEEPY) face.setState(FaceView.State.IDLE);
    }

    /** 錄到說完為止；太短（雜音）回傳 null。 */
    private byte[] record(AudioRecord rec, ArrayDeque<short[]> preroll, short[] first, double noise, boolean manual) {
        face.setState(FaceView.State.LISTENING);
        face.setEmotion("happy");
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        for (short[] f : preroll) writePcm(out, f, f.length);
        writePcm(out, first, FRAME);

        double thresh = Math.max(Config.VAD_MIN_RMS, noise * Config.VAD_RATIO) * 0.6;
        int speechMs = manual ? 0 : FRAME_MS, silenceMs = 0, totalMs = 0;
        int silenceLimit = Config.VAD_SILENCE_MS + (manual ? 600 : 0);
        short[] buf = new short[FRAME];
        while (running && totalMs < Config.MAX_RECORD_SEC * 1000) {
            int n = rec.read(buf, 0, FRAME);
            if (n <= 0) continue;
            writePcm(out, buf, n);
            double rms = rms(buf, n);
            face.setLevel((float) Math.min(1.0, rms / 3000.0));
            totalMs += FRAME_MS;
            if (rms > thresh) { speechMs += FRAME_MS; silenceMs = 0; }
            else silenceMs += FRAME_MS;
            // 手動模式一開始給 4 秒時間開口
            if (manual && speechMs == 0 && totalMs < 4000) continue;
            if (silenceMs >= silenceLimit) break;
        }
        if (speechMs < Config.VAD_MIN_SPEECH_MS) {
            if (manual) face.setStatus("沒聽到聲音耶，再說一次？");
            return null;
        }
        return out.toByteArray();
    }

    private void handleSpeech(byte[] pcm) {
        interrupted = false;
        face.setState(FaceView.State.THINKING);
        face.setSubtitle("");
        String text = ai.transcribe(pcm);
        if (text.isEmpty()) {
            showError(ai.lastError.isEmpty() ? "沒聽清楚，再說一次好嗎？" : ai.lastError);
            return;
        }
        face.setUserText(text);
        String lc = text.toLowerCase();
        if (lc.contains("deck") || text.contains("快捷面板") || text.contains("按鍵面板")) {   // 語音開 Stream Deck
            face.setState(FaceView.State.IDLE);
            runOnUiThread(this::openDeck);
            return;
        }
        Music.Request req = music.parse(text);              // 唱歌 / 點歌 / 看 MV / 問歌單 → 不經過 AI
        if (req.kind == Music.PLAY) { sing(req.song != null ? req.song : music.random(false)); return; }
        if (req.kind == Music.MV) {
            Music.Song song = req.song != null ? req.song : music.random(true);
            if (song.mp4.isEmpty()) {
                say("〈" + song.name + "〉還沒有 MV，我先唱給你聽喔！", "shy");
                sing(song);
            } else {
                say("好喔！來看〈" + song.name + "〉的 MV。", "happy");
                if (!interrupted) runOnUiThread(() -> playMV(song));
            }
            return;
        }
        if (req.kind == Music.LIST) {
            StringBuilder names = new StringBuilder();
            for (int i = 0; i < Math.min(8, music.songs.size()); i++)
                names.append(i > 0 ? "、" : "").append("〈").append(music.songs.get(i).name).append("〉");
            say("我會唱 " + music.songs.size() + " 首吳玉柱先生的自創歌曲，像是" + names + "。想聽哪一首，說歌名就可以喔！", "happy");
            return;
        }
        String reply = ai.chat(text);
        if (reply.isEmpty()) {
            showError("連線失敗：" + ai.lastError);
            return;
        }
        face.setEmotion(ai.lastEmotion);
        face.setSubtitle(reply);
        face.setState(FaceView.State.SPEAKING);
        if (!ai.speak(reply)) showError("語音播放失敗：" + ai.lastError);
    }

    /** 先用語音報歌名，再串流播放雲端的 mp3；播放中嘴巴會動，點螢幕可停止。 */
    private void sing(Music.Song song) {
        say("好喔！為你播放〈" + song.name + "〉。", "happy");
        if (interrupted) return;                             // 報歌名時被點掉 → 不播
        face.setSubtitle("♪ 正在播放〈" + song.name + "〉\n\n點一下螢幕可以停止");
        boolean ok = music.play(song);
        if (!ok && !interrupted) showError("歌曲播放失敗，請確認網路，或雲端檔案是否仍公開分享");
    }

    /** 說一段固定的話（不經過 AI）。 */
    private void say(String text, String emotion) {
        face.setEmotion(emotion);
        face.setSubtitle(text);
        face.setState(FaceView.State.SPEAKING);
        if (!ai.speak(text)) showError("語音播放失敗：" + ai.lastError);
    }

    // ---------------- MV（全螢幕，Google 雲端 songs_mp4 串流）----------------
    private void buildMvUi(FrameLayout root) {
        mvLayer = new FrameLayout(this);
        mvLayer.setBackgroundColor(Color.BLACK);
        mvView = new VideoView(this);
        FrameLayout.LayoutParams vp = new FrameLayout.LayoutParams(-1, -1);
        vp.gravity = Gravity.CENTER;
        mvLayer.addView(mvView, vp);
        MediaController mc = new MediaController(this);           // 點影片 → 進度條
        mc.setAnchorView(mvView);
        mvView.setMediaController(mc);
        mvView.setOnCompletionListener(mp -> closeMV());
        mvView.setOnErrorListener((mp, what, extra) -> {
            closeMV();
            face.setStatus("MV 播放失敗，請確認網路，或雲端檔案是否仍公開分享");
            return true;
        });

        LinearLayout bar = new LinearLayout(this);
        bar.setOrientation(LinearLayout.HORIZONTAL);
        bar.setGravity(Gravity.CENTER_VERTICAL);
        mvPause = mvButton("⏸ 暫停");
        mvPause.setOnClickListener(v -> toggleMVPause());
        Button stop = mvButton("⏹ 停止");
        stop.setOnClickListener(v -> closeMV());
        mvTitle = new TextView(this);
        mvTitle.setTextColor(0xD9FFFFFF);
        mvTitle.setTextSize(15);
        mvTitle.setShadowLayer(4, 0, 0, Color.BLACK);
        bar.addView(mvPause);
        bar.addView(stop);
        bar.addView(mvTitle);
        FrameLayout.LayoutParams bp = new FrameLayout.LayoutParams(-2, -2);
        bp.gravity = Gravity.TOP | Gravity.START;
        bp.leftMargin = 16; bp.topMargin = 16;
        mvLayer.addView(bar, bp);
        mvLayer.setVisibility(View.GONE);
        root.addView(mvLayer, new FrameLayout.LayoutParams(-1, -1));
    }

    private Button mvButton(String label) {
        Button b = new Button(this);
        b.setAllCaps(false);
        b.setText(label);
        b.setTextSize(17);
        b.setTextColor(Color.WHITE);
        b.setBackgroundColor(0x99000000);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-2, -2);
        lp.rightMargin = 12;
        b.setLayoutParams(lp);
        return b;
    }

    private void playMV(Music.Song song) {
        ai.stopSpeaking();
        music.stop();
        webShown = true;                                      // MV 聲音不要觸發語音偵測
        mvTitle.setText(song.name);
        mvPause.setText("⏸ 暫停");
        mvLayer.setVisibility(View.VISIBLE);
        mvLayer.bringToFront();
        mvView.setVideoURI(android.net.Uri.parse(Music.url(song.mp4)));
        mvView.start();
    }

    private void toggleMVPause() {
        if (mvView.isPlaying()) { mvView.pause(); mvPause.setText("▶︎ 繼續"); }
        else { mvView.start(); mvPause.setText("⏸ 暫停"); }
    }

    private boolean mvOpen() { return mvLayer != null && mvLayer.getVisibility() == View.VISIBLE; }

    private void closeMV() {
        if (!mvOpen()) return;
        mvView.stopPlayback();
        mvLayer.setVisibility(View.GONE);
        webShown = webOpen();
        hideSystemUi();
    }

    private void showError(String msg) {
        face.setState(FaceView.State.ERROR);
        face.setEmotion("sad");
        face.setSubtitle(msg);
        sleep(2500);
        face.setEmotion("happy");
    }

    // ---------------- 工具 ----------------
    private AudioRecord openMic() {
        int min = AudioRecord.getMinBufferSize(RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT);
        int[] sources = {MediaRecorder.AudioSource.VOICE_RECOGNITION, MediaRecorder.AudioSource.MIC};
        for (int src : sources) {
            try {
                AudioRecord r = new AudioRecord(src, RATE, AudioFormat.CHANNEL_IN_MONO,
                        AudioFormat.ENCODING_PCM_16BIT, Math.max(min, RATE));
                if (r.getState() == AudioRecord.STATE_INITIALIZED) return r;
                r.release();
            } catch (Exception ignored) {}
        }
        return null;
    }

    private static void drain(AudioRecord rec, short[] buf, int ms) {
        for (int t = 0; t < ms; t += FRAME_MS) rec.read(buf, 0, FRAME);
    }

    private static double rms(short[] b, int n) {
        double s = 0;
        for (int i = 0; i < n; i++) s += (double) b[i] * b[i];
        return Math.sqrt(s / Math.max(1, n));
    }

    private static void writePcm(ByteArrayOutputStream out, short[] b, int n) {
        for (int i = 0; i < n; i++) {
            out.write(b[i] & 0xff);
            out.write((b[i] >> 8) & 0xff);
        }
    }

    private static void sleep(long ms) {
        try { Thread.sleep(ms); } catch (InterruptedException ignored) {}
    }
}
